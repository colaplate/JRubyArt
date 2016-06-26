# frozen_string_literal: false

require 'ostruct'
require 'fileutils'
require 'rbconfig'
require_relative '../jruby_art/config'
require_relative '../jruby_art/version'
require_relative '../jruby_art/installer'
require_relative '../jruby_art/java_opts'

# processing wrapper module
module Processing
  # Utility class to handle the different commands that the 'k9' command
  # offers. Able to run, watch, live, create, app, and unpack
  class Runner
    HELP_MESSAGE ||= <<-EOS
    Version: #{JRubyArt::VERSION}

    JRubyArt is a little shim between Processing and JRuby that helps
    you create sketches of code art.

    Usage:
    k9 [choice] sketch

    choice:-
    run:              run sketch once
    watch:            watch for changes on the file and relaunch it on the fly
    live:             run sketch and open a pry console bound to $app
    create [width height][mode][flag]: create a new sketch.
    setup:            check / install / unpack_samples

    Common options:
    --nojruby:  use jruby-complete in place of an installed version of jruby
    (Set [JRUBY: 'false'] in .jruby_art/config.yml to make using jruby-complete default)

    Examples:
    k9 setup unpack_samples
    k9 run rp_samples/samples/contributed/jwishy.rb
    k9 create some_new_sketch 640 480 p3d (P3D mode example)
    k9 create some_new_sketch 640 480 --wrap (a class wrapped default sketch)
    k9 watch some_new_sketch.rb

    Everything Else:
    https://ruby-processing.github.io/

    EOS

    WIN_PATTERNS = [
      /bccwin/i,
      /cygwin/i,
      /djgpp/i,
      /ming/i,
      /mswin/i,
      /wince/i
    ]

    attr_reader :os

    # Start running a jruby_art sketch from the passed-in arguments
    def self.execute
      runner = new
      runner.parse_options(ARGV)
      runner.execute!
    end

    # Dispatch central.
    def execute!
      case @options.action
      when 'run'    then run(@options.path, @options.args)
      when 'live'   then live(@options.path, @options.args)
      when 'watch'  then watch(@options.path, @options.args)
      when 'create' then create(@options.path, @options.args)
      when 'setup'  then setup(@options.path)
      when /-v/     then show_version
      when /-h/     then show_help
      else
        show_help
      end
    end

    # Parse the command-line options. Keep it simple.
    def parse_options(args)
      @options = OpenStruct.new
      @options.emacs = !args.delete('--emacs').nil?
      @options.wrap = !args.delete('--wrap').nil?
      @options.inner = !args.delete('--inner').nil?
      @options.jruby = !args.delete('--jruby').nil?
      @options.nojruby = !args.delete('--nojruby').nil?
      @options.action = args[0] || nil
      @options.path = args[1] || File.basename(Dir.pwd + '.rb')
      @options.args = args[2..-1] || []
    end

    # Create a fresh JRubyArt sketch, with the necessary
    # boilerplate filled out.
    def create(sketch, args)
      require_relative '../jruby_art/creators/creator'
      return Creator::Inner.new.create!(sketch, args) if @options.inner
      return Creator::ClassSketch.new.create!(sketch, args) if @options.wrap
      return Creator::EmacsSketch.new.create!(sketch, args) if @options.emacs
      Creator::BasicSketch.new.create!(sketch, args)
    end

    # Just simply run a JRubyArt sketch.
    def run(sketch, args)
      ensure_exists(sketch)
      spin_up('run.rb', sketch, args)
    end

    # Just simply run a JRubyArt sketch.
    def live(sketch, args)
      ensure_exists(sketch)
      spin_up('live.rb', sketch, args)
    end

    # Run a sketch, keeping an eye on it's file, and reloading
    # whenever it changes.
    def watch(sketch, args)
      ensure_exists(sketch)
      spin_up('watch.rb', sketch, args)
    end

    def setup(choice)
      return Check.new(K9_ROOT, host_os).install if choice =~ /check/
      return JRubyComplete.new(K9_ROOT, host_os).install if choice =~ /install/
      return UnpackSamples.new(K9_ROOT, host_os).install if choice =~ /unpack_sample/
      Installer.new(K9_ROOT, host_os).install
    end

    # Show the standard help/usage message.
    def show_help
      puts HELP_MESSAGE
    end

    def show_version
      puts format('JRubyArt version %s', JRubyArt::VERSION)
    end

    private

    # Trade in this Ruby instance for a JRuby instance, loading in a starter
    # script and passing it some arguments. Unless '--nojruby' is passed, the
    # installed version of jruby is used instead of our vendored one. To use
    # jruby-complete by default set JRUBY: false in ~/.jruby_art/config.yml
    # (however that might make using other gems in your sketches hard....)
    def spin_up(starter_script, sketch, args)
      runner = "#{K9_ROOT}/lib/jruby_art/runners/#{starter_script}"
      @options.nojruby = true if Processing::RP_CONFIG['JRUBY'] == 'false'
      opts = JavaOpts.new(SKETCH_ROOT)
      if @options.nojruby
        command = ['java',
                   opts.jvm_opts,
                   '-cp',
                   jruby_complete,
                   'org.jruby.Main',
                   runner,
                   sketch,
                   args].flatten
      else
        command = ['jruby',
                   opts.jruby,
                   runner,
                   sketch,
                   args].flatten
      end
      begin
        exec(*command)
        # exec replaces the Ruby process with the JRuby one.
      rescue Java::JavaLang::ClassNotFoundException
      end
    end

    # NB: We really do mean to use 'and' not '&&' for flow control purposes

    def ensure_exists(sketch)
      puts "Couldn't find: #{sketch}" and exit unless FileTest.exist?(sketch)
    end

    def jruby_complete
      rcomplete = File.join(K9_ROOT, 'lib/ruby/jruby-complete.jar')
      return [rcomplete] if FileTest.exist?(rcomplete)
      warn "#{rcomplete} does not exist\nTry running `k9 setup install`"
      exit
    end

    def libraries
      %w(video sound).map { |library| sketchbook_library(library) }.flatten
    end

    def sketchbook_library(name)
      Dir["#{Processing::RP_CONFIG['sketchbook_path']}/libraries/#{name}/library/\*.jar"]
    end

    def host_os
      detect_os = RbConfig::CONFIG['host_os']
      case detect_os
      when /mac|darwin/ then :mac
      when /linux/ then :linux
      when /solaris|bsd/ then :unix
      else
        WIN_PATTERNS.find { |r| detect_os =~ r }
        raise "unknown os: #{detect_os.inspect}" if Regexp.last_match.nil?
        :windows
      end
    end
  end # class Runner
end # module Processing
