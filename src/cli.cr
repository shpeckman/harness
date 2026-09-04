# src/cli.cr
require "option_parser"
require "./harness"

# dsh — the Harness one-shot CLI.
#
#   dsh [PROMPT]                       run one task with the headless profile
#   dsh --profile FILE [PROMPT]        boot a custom profile
#   dsh --patch FILE [PROMPT]          overlay a patch after the profile layers
#   dsh --dump-config                  print the composed plugin rows and exit
#
# The prompt may also come from stdin: `echo "task" | dsh`.

profile     = "headless"
patches     = [] of String
dump_config = false
prompt : String? = nil

parser = OptionParser.new do |opts|
  opts.banner = <<-BANNER
    Usage: dsh [--profile NAME|PATH] [--patch FILE]... [--dump-config] [PROMPT]

    An everything-is-a-plugin agent harness. Every application starts at this
    CLI with a named profile; the shipped profile is "headless".

    Options:
    BANNER
  opts.on("--profile NAME", "Profile: shipped name (headless) or path to profile YAML") { |v| profile = v }
  opts.on("--patch FILE", "Patch YAML applied after the profile layers (repeatable)") { |v| patches << File.read(v) }
  opts.on("--dump-config", "Print the composed plugin rows and exit") { dump_config = true }
  opts.on("-v", "--version", "Print version and exit") { puts "dsh #{Harness::VERSION}"; exit }
  opts.on("-h", "--help", "Show this help and exit") { puts opts; exit }
  opts.unknown_args { |args| prompt = args.join(" ") unless args.empty? }
end
parser.parse

begin
  composition = Harness::Composition.load(profile, patches)

  if dump_config
    puts composition.dump
    exit
  end

  if prompt.nil? && !STDIN.tty?
    piped  = STDIN.gets_to_end.strip
    prompt = piped unless piped.empty?
  end
  unless prompt
    STDERR.puts "no prompt given (pass one as an argument or via stdin; see dsh --help)"
    exit 64
  end
  task = prompt.not_nil!

  app = Harness::App.boot(composition)
  begin
    # The headless ask-handler: prompt on stderr, read the answer from stdin.
    if approval = app.root.service?("approval", Harness::Approval)
      approval.ask_handler = ->(tool : String, detail : String) do
        STDERR.print "approve #{tool} #{detail[0, 120]}? [y/N] "
        answer = STDIN.gets
        !answer.nil? && answer.strip.downcase == "y"
      end
    end

    agent = app.agents.create
    puts agent.run(task)
  ensure
    app.dispose
  end
rescue ex
  STDERR.puts "dsh: #{ex.message}"
  exit 1
end
