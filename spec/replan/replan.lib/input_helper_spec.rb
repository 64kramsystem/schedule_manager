require 'rspec'
require 'reline'
require 'pty'
require 'tempfile'
require 'timeout'
require 'shellwords'

require_relative '../../../replan.lib/input_helper.rb'

describe InputHelper do
  describe '#ask' do
    before do
      Reline.pre_input_hook = nil
      allow($stdout).to receive(:puts)
    end

    after do
      Reline.pre_input_hook = nil
    end

    it 'returns the value entered by the user' do
      allow(Reline).to receive(:readline).and_return('user input')

      result = described_class.new.ask('Enter something:')

      expect(result).to eq('user input')
    end

    it 'pre-fills the editable buffer via Reline.insert_text when a prefill is provided' do
      expect(Reline).to receive(:insert_text).with('my prefill')
      allow(Reline).to receive(:redisplay)

      allow(Reline).to receive(:readline) do
        Reline.pre_input_hook.call
        'returned'
      end

      described_class.new.ask('Enter something:', prefill: 'my prefill')
    end

    it "restores the prefill's leading whitespace and strips the user input's" do
      expect(Reline).to receive(:insert_text).with('foo')
      allow(Reline).to receive(:redisplay)
      allow(Reline).to receive(:readline) do
        Reline.pre_input_hook.call
        '  bar'
      end

      result = described_class.new.ask('Enter something:', prefill: '   foo')

      expect(result).to eq('   bar')
    end

    it 'does not register a pre_input_hook when the prefill is whitespace-only' do
      hook_during_readline = :unset
      allow(Reline).to receive(:readline) do
        hook_during_readline = Reline.pre_input_hook
        'bar'
      end

      result = described_class.new.ask('Enter something:', prefill: '   ')

      expect(hook_during_readline).to be_nil
      expect(result).to eq('   bar')
    end

    it 'does not register a pre_input_hook when prefill is empty' do
      hook_during_readline = :unset
      allow(Reline).to receive(:readline) do
        hook_during_readline = Reline.pre_input_hook
        'returned'
      end

      described_class.new.ask('Enter something:')

      expect(hook_during_readline).to be_nil
    end

    it 'clears the pre_input_hook after the call returns' do
      allow(Reline).to receive(:readline).and_return('returned')
      allow(Reline).to receive(:insert_text)
      allow(Reline).to receive(:redisplay)

      described_class.new.ask('Enter something:', prefill: 'pre')

      expect(Reline.pre_input_hook).to be_nil
    end

    # Integration test against a real TTY via PTY, to prove that Reline actually presents the
    # prefill as an editable buffer (not just that we wired the hooks correctly).
    #
    it 'produces an editable prefilled buffer under a real Reline (pty integration)' do
      input_helper_path = File.expand_path('../../../replan.lib/input_helper.rb', __dir__)
      result_file = Tempfile.new('input_helper_result')
      result_file.close

      child_script = <<~RUBY
        require #{input_helper_path.inspect}
        result = InputHelper.new.ask('prompt:', prefill: 'hello world')
        File.write(#{result_file.path.inspect}, result)
      RUBY

      Timeout.timeout(5) do
        PTY.spawn('ruby', '-e', child_script) do |reader, writer, pid|
          # Wait for Reline to echo the inserted prefill before sending Enter.
          #
          buffer = ''
          buffer << reader.readpartial(1024) until buffer.include?('hello world')

          writer.write("\n")
          Process.wait(pid)
        end
      end

      expect(File.read(result_file.path)).to eq('hello world')
    ensure
      result_file&.unlink
    end
  end
end
