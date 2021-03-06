# Top level class of the FigTree gem
class FigFig
  MissingConfigurationError           = Class.new StandardError
  DuplicateParameterDefinitionError   = Class.new StandardError
  CannotModifyLockedParameterError    = Class.new StandardError
  InvalidLockOptionError              = Class.new StandardError
  ConfigurationAlreadyDefinedError    = Class.new StandardError

  class << self
    attr_accessor :configuration

    # And we define a wrapper for the configuration block, that we'll use to set up
    # our set of options
    def configure(reset: nil)
      self.reset if reset
      raise ConfigurationAlreadyDefinedError if @configuration
      @configuration = ConfigurationContainer.new
      @configuration.configuring = true
      yield configuration if block_given?
      @configuration.configuring = false
    end

    def configuration
      @configuration ||= ConfigurationContainer.new
    end

    def reset
      @configuration = nil
    end

    def method_missing(method_name, *args, &blk)
      return super unless configuration.respond_to? method_name
      configuration.send method_name, *args, &blk
    end

    def respond_to_missing?(method, _include_private = false)
      configuration.respond_to?(method) || super
    end
  end

  # The class that encapsulates the current configuration definition and parameter values
  class ConfigurationContainer
    attr_accessor :parameters,
                  :after_validation_callbacks,
                  :configuring,
                  :validating,
                  :readied, # set to true during the ready lifecycle event
                  :validated # set to true during the validation lifecycle event

    def initialize
      @configuring = false
      @validating = false
    end

    def parameter(name, options = {})
      @parameters ||= []
      raise DuplicateParameterDefinitionError if parameters.any? { |p| p.keys.first == name }
      parameters << { name: name.to_s, options: options, value: nil, set: false }
    end

    def valid?
      @validating = true
      _missing_configuration if _invalid_parameters.any?
      # Set validated to true to block changes to parameters with on_validation locks
      # including those in after_validation callbacks
      @validated = true
      Array(@after_validation_callbacks).each do |callback|
        callback.call self
      end
      # Below line is the final_validation lifecycle event
      _missing_configuration if _invalid_parameters.any?
      @validating = false
      @validated
    end

    def validated
      @validated ||= false
    end

    def ready
      valid?
      @readied = true
    end

    def readied
      @readied ||= false
    end

    def after_validation(&blk)
      @after_validation_callbacks ||= []
      @after_validation_callbacks << blk
    end

    def method_missing(method_name, *args, &blk)
      method_name_str = method_name.to_s
      return super unless _dynamically_exposed_methods.include? method_name_str
      if _dynamically_exposed_readers.include? method_name_str
        _ghost_reader method_name_str, *args, &blk
      elsif _dynamically_exposed_writers.include? method_name_str
        _ghost_writer method_name_str, *args, &blk
      end
    end

    def respond_to_missing?(method_name, _include_private = false)
      _dynamically_exposed_methods.include?(method_name.to_s) || super
    end

    def locked?(parameter)
      lock_option = parameter[:options].fetch(:lock, nil)
      case lock_option
      when nil
        false
      when :on_set
        parameter[:set]
      when :on_validation
        validated
      when :on_ready
        readied
      else
        raise InvalidLockOptionError
      end
    end

    private

    def _ghost_reader(method_name_str, *_args)
      parameters.detect { |p| p[:name] == method_name_str }[:value]
    end

    def _ghost_writer(method_name_str, *args)
      parameter = parameters.detect { |p| "#{p[:name]}=" == method_name_str }
      raise CannotModifyLockedParameterError if locked? parameter
      parameter[:value] = args.first
      parameter[:set] = true
      parameter[:value]
    end

    def _missing_configuration
      raise MissingConfigurationError,
            "All required configurations have not been set. Missing configurations: #{_invalid_parameter_names}"
    end

    def _dynamically_exposed_methods
      _dynamically_exposed_readers | _dynamically_exposed_writers
    end

    def _dynamically_exposed_readers
      (readied || configuring || validating) ? parameters.map { |p| p[:name] } : []
    end

    def _dynamically_exposed_writers
      parameters.map { |p| "#{p[:name]}=" }
    end

    def _invalid_parameters
      parameters.
        select { |p| p[:options].fetch(:required, false) }.
        select { |p| send(p[:name]).nil? }
    end

    def _invalid_parameter_names
      _invalid_parameters.map { |p| p[:name] }.join(",")
    end
  end
end
