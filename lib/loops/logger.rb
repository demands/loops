require 'logger'
require 'delegate'
require 'fileutils'

class Loops::Logger < ::Delegator
  DEBUG = 0
  INFO = 1
  WARN = 2
  ERROR = 3
  FATAL = 4
  LOG_SEVERITIES = {
    :debug => DEBUG,
    :info =>  INFO,
    :warn =>  WARN,
    :error => ERROR,
    :fatal => FATAL,
    DEBUG => DEBUG,
    INFO => INFO,
    WARN => WARN,
    ERROR => ERROR,
    FATAL => FATAL
  }

  # @return [Boolean]
  #   A value indicating whether all logging output should be
  #   also duplicated to the console.
  attr_reader :write_to_console

  # @return [Boolean]
  #   A value inidicating whether critical errors should be highlighted
  #   with ANSI colors in the log.
  attr_reader :colorful_logs

  # Initializes a new instance of the {Logger} class.
  #
  # @param [String, IO] logfile
  #   The log device.  This is a filename (String), <tt>'stdout'</tt> or
  #   <tt>'stderr'</tt> (String), <tt>'default'</tt> for default framework's
  #   log file, or +IO+ object (typically +STDOUT+, +STDERR+,
  #   or an open file).
  # @param [Integer] level
  #   Logging level. Constants are defined in +Logger+ namespace: +DEBUG+, +INFO+,
  #   +WARN+, +ERROR+, +FATAL+, or +UNKNOWN+.
  # @param [Boolean] write_to_console
  #   When +true+, all logging output will be dumped to the +STDOUT+ also.
  #
  def initialize(logfile = $stdout, level = :info, write_to_console = false)
    @write_to_console = write_to_console
    @level = level
    self.logfile = logfile
    super(@implementation)
  end

  # Sets the default log file (see {#logfile=}).
  #
  # @param [String, IO] logfile
  #   the log file path or IO.
  # @return [String, IO]
  #   the log file path or IO.
  #
  def default_logfile=(logfile)
    @default_logfile = logfile
    self.logfile = logfile
  end

  # Sets the log file.
  #
  # @param [String, IO] logfile
  #   The log device.  This is a filename (String), <tt>'stdout'</tt> or
  #   <tt>'stderr'</tt> (String), <tt>'default'</tt> for default framework's
  #   log file, or +IO+ object (typically +STDOUT+, +STDERR+,
  #   or an open file).
  # @return [String, IO]
  #   the log device.
  #
  def logfile=(logfile)
    logfile = @default_logfile || $stdout if logfile == 'default'
    coerced_logfile =
        case logfile
        when 'stdout' then $stdout
        when 'stderr' then $stderr
        when IO, StringIO then logfile
        else
          if Loops.root
            logfile =~ /^\// ? logfile : Loops.root.join(logfile).to_s
          else
            logfile
          end
        end
    # Ensure logging directory does exist
    FileUtils.mkdir_p(File.dirname(coerced_logfile)) if String === coerced_logfile

    # Create a logger implementation.
    @implementation = LoggerImplementation.new(coerced_logfile, @write_to_console, @colorful_logs)
    @implementation.level = @level
    logfile
  end

  # Remember the level at the proxy level.
  #
  # @param [Integer] level
  #   Logging severity.
  # @return [Integer]
  #   Logging severity.
  #
  def level=(level)
    @level = level
    @implementation.level = @level if @implementation
    level
  end

  # Sets a value indicating whether to dump all logs to the console.
  #
  # @param [Boolean] value
  #   a value indicating whether to dump all logs to the console.
  # @return [Boolean]
  #   a value indicating whether to dump all logs to the console.
  #
  def write_to_console=(value)
    @write_to_console = value
    @implementation.write_to_console = value if @implementation
    value
  end

  # Sets a value indicating whether to highlight with red ANSI color
  # all critical messages.
  #
  # @param [Boolean] value
  #   a value indicating whether to highlight critical errors in log.
  # @return [Boolean]
  #   a value indicating whether to highlight critical errors in log.
  #
  def colorful_logs=(value)
    @colorful_logs = value
    @implementation.colorful_logs = value if @implementation
    value
  end

  # @private
  # Send everything else to @implementation.
  def __getobj__
    @implementation or raise "Logger implementation not initialized"
  end

  def __setobj__(obj)
    @implementation = obj
  end

  # @private
  # Delegator's method_missing ignores the &block argument (!!!?)
  def method_missing(m, *args, &block)
    target = self.__getobj__
    unless target.respond_to?(m)
      super(m, *args, &block)
    else
      target.__send__(m, *args, &block)
    end
  end

  # @private
  class LoggerImplementation

    attr_reader :prefix

    attr_accessor :write_to_console, :colorful_logs

    class Formatter
      def initialize(logger)
        @logger = logger
      end

      def call(severity, time, message)
        if (@logger.prefix || '').empty?
          "#{severity[0..0]} : #{time.strftime('%Y-%m-%d %H:%M:%S')} : #{message}\n"
        else
          "#{severity[0..0]} : #{time.strftime('%Y-%m-%d %H:%M:%S')} : #{@logger.prefix} : #{message}\n"
        end
      end
    end

    def initialize(log_device, write_to_console = true, colorful_logs = false)
      @log_device_descriptor = log_device
      @formatter             = Formatter.new(self)
      @write_to_console      = write_to_console
      @colorful_logs         = colorful_logs
      @prefix                = nil
      @level                 = INFO

      @log_device            = log_device_resource
    end

    LOG_SEVERITIES.keys.each do |severity|
      break unless Symbol === severity
      class_eval <<-EVAL, __FILE__, __LINE__
        def #{severity}(message)
          add(#{LOG_SEVERITIES[severity]}, message) unless(LOG_SEVERITIES[@level] > #{LOG_SEVERITIES[severity]})
        end
      EVAL
    end

    def add(severity, message = nil)
      begin
        message = color_errors(severity, message) if @colorful_logs
        message = @formatter.call(%w(D I W E F A)[severity] || 'A', Time.now, message)
        @log_device.puts(message)
        @log_device.flush
        puts message if @write_to_console && message
        # ignore errors in logging
      end
    end

    def log_device_resource
      if String === @log_device_descriptor
        File.new(@log_device_descriptor, 'w')
      elsif IO === @log_device_descriptor
        @log_device_descriptor
      end
    end

    def reopen_logs!
      @log_device.reopen(log_device_resource)
    end

    def level=(level)
      @level = LOG_SEVERITIES[level] if LOG_SEVERITIES[level]
    end

    def color_errors(severity, line)
      if severity < ERROR
        line
      else
        if line && line !~ /\e/
          "\e[31m#{line}\e[0m"
        else
          line
        end
      end
    end

  end
end
