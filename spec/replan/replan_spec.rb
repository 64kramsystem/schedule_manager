require 'rspec'
require 'tmpdir'
require 'timecop'
require 'open3'
require 'rbconfig'

load File.expand_path('../../replan', __dir__)

describe Replan do
  let(:current_day) do
    <<~TXT
          MON 20/SEP/2021
      - daily task (replan 1)
      - work 2h
      -----
      -----
      -----
      -----

    TXT
  end

  let(:next_day) do
    <<~TXT
          TUE 21/SEP/2021
      - existing next day
      #LPIM_REPLACE
      -----
      -----
      -----
      -----

    TXT
  end

  let(:selected_day) do
    <<~TXT
          WED 22/SEP/2021
      - existing selected day
      -----
      -----
      -----
      -----

    TXT
  end

  let(:template) do
    <<~TXT
      -^ template task
      -----
      -----
      -----
      -----
    TXT
  end

  let(:schedule) { current_day + next_day + selected_day }
  let(:schedule_filename) { File.join(@directory, 'schedule') }
  let(:archive_filename) { File.join(@directory, 'archive') }
  let(:template_filename) { File.join(@directory, 'template') }

  around do |example|
    Dir.mktmpdir('replan-spec-', '/tmp') do |directory|
      @directory = directory
      Timecop.freeze(Date.new(2021, 9, 21)) { example.run }
    end
  end

  before do
    File.write(schedule_filename, schedule)
    File.write(archive_filename, "Existing archive\n")
    File.write(template_filename, template)
    stub_const('Readder::DEFAULT_DAYS_TO_ADD', 2)
  end

  describe 'export error reporting' do
    it 'shows errors and the retry prompt on stderr before waiting for input' do
      File.write(schedule_filename, current_day + "- misplaced task\n")
      File.write(archive_filename, '')
      config_filename = File.join(@directory, '.replan')
      File.write(config_filename, "schedule_filename=#{schedule_filename}\narchive_filename=#{archive_filename}\nevent_symbols=*PS%&\n")
      bootstrap = <<~RUBY
        require 'simple_scripting/configuration'
        require 'timecop'
        Timecop.freeze(Date.new(2021, 9, 21))
        config_filename = ARGV.shift
        SimpleScripting::Configuration.define_singleton_method(:default_config_file) { config_filename }
        $PROGRAM_NAME = ARGV.shift
        load $PROGRAM_NAME
      RUBY
      command = [RbConfig.ruby, '-e', bootstrap, config_filename, File.expand_path('../../replan', __dir__), '-x', '2021-09-20']

      Open3.popen3(*command) do |stdin, stdout, stderr, process|
        begin
          expect(IO.select([stderr], nil, nil, 5)).not_to be_nil
          expect(stderr.gets).to include('ERROR:', 'not a correct date header', '- misplaced task')
          expect(stderr.gets).to eq("Repair the file, then press Enter to retry (Ctrl+C to cancel).\n")
          expect(process).to be_alive
        ensure
          stdin.close
        end

        expect(stdout.read).to eq('')
        expect(process.value.exitstatus).to eq(1)
      end
    end
  end

  describe '#apply_template' do
    it "preserves escaped matchers and literal backreferences through template insertion" do
      content = schedule.sub('- existing selected day', %q{- it's ready})
      replacement_template = template.sub('-^ template task') { %q{- {{replace 'it\'s ready'}} \0 \& \\'} }
      File.write(schedule_filename, content)
      File.write(template_filename, replacement_template)

      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expected = content.sub(%q{- it's ready}) { %q{- \0 \& \\'} }
      expect(File.read(schedule_filename)).to eq(expected)
    end

    it "resolves replacement directives only on the selected date" do
      other_day = current_day.sub('- work 2h', '- {{replace "missing"}} other replacement')
      File.write(schedule_filename, other_day + next_day + selected_day)
      File.write(template_filename, template.sub('-^ template task', '- {{replace "existing selected day"}} replacement'))

      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expect(File.read(schedule_filename)).to eq(other_day + next_day + selected_day.sub('- existing selected day', '- replacement'))
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "changes only the selected date and leaves current-day work and the archive untouched" do
      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expected_day = <<~TXT
            WED 22/SEP/2021
        - template task
        - existing selected day
        -----
        -----
        -----
        -----

      TXT

      expect(File.read(schedule_filename)).to eq(current_day + next_day + expected_day)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "applies the template when the selected final section has no terminating blank line" do
      File.write(schedule_filename, schedule.chomp)

      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expect(File.read(schedule_filename)).to eq(schedule.sub('- existing selected day', "- template task\n- existing selected day"))
    end

    it "requires a template without changing the schedule or archive" do
      expect {
        subject.apply_template(schedule_filename, template_filename: nil, day: Date.new(2021, 9, 22), compare: false)
      }.to raise_error('template_filename is required in day mode')

      expect(File.read(schedule_filename)).to eq(schedule)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "rejects a missing date section without changing the schedule or archive" do
      expect {
        subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 23), compare: false)
      }.to raise_error('Header not found after date: 2021-09-23')

      expect(File.read(schedule_filename)).to eq(schedule)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "leaves the schedule and archive untouched when comparison is declined" do
      stub_const('MERGE_PROGRAM', '/usr/bin/true')
      allow($stdin).to receive(:getch).and_return('n')

      expect {
        subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: true)
      }.to output(/Changes not committed!/).to_stdout

      expect(File.read(schedule_filename)).to eq(schedule)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end
  end

  describe '#update' do
    let(:processed_next_day) do
      <<~TXT
            TUE 21/SEP/2021
        - existing next day
        ; lpimw -t 2021-09-20 '2h' # -c half|off # Mon
        - daily task (replan 1)
        -----
        -----
        -----
        -----

      TXT
    end

    let(:archived_day) do
      <<~TXT
            MON 20/SEP/2021
        - daily task
        - work 2h
        -----
        -----
        -----
        -----

      TXT
    end

    it "preserves literal backreferences in replacements throughout replanning" do
      content = schedule.sub('- existing next day', %q{- it's ready})
      replacement_template = template.sub('-^ template task') { %q{- {{replace 'it\'s ready'}} \0 \& \\'} }
      File.write(schedule_filename, content)
      File.write(template_filename, replacement_template)

      subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: false, debug: false)

      expected_next_day = processed_next_day.sub('- existing next day') { %q{- \0 \& \\'} }
      expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it "resolves replacement directives inserted by the template before processing the schedule" do
      File.write(template_filename, template.sub('-^ template task', '; {{replace "existing next day"}} replacement'))

      subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: false, debug: false)

      expect(File.read(schedule_filename)).to eq(processed_next_day.sub('- existing next day', '; replacement') + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it "leaves files untouched when a replacement has no target" do
      File.write(template_filename, template.sub('-^ template task', '- {{replace "missing"}} replacement'))

      expect {
        subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: false, debug: false)
      }.to raise_error(/requires exactly one matching line; found 0/)

      expect(File.read(schedule_filename)).to eq(schedule)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "leaves replacement directives untouched in skips-only mode" do
      content = schedule.sub('- work 2h', '- {{replace "missing"}} replacement')
      File.write(schedule_filename, content)

      subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: true, debug: false)

      expect(File.read(schedule_filename)).to eq(content)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "processes and archives the current day without applying a template" do
      subject.update(schedule_filename, archive_filename, template_filename: nil, compare: false, skips_only: false, debug: false)

      expect(File.read(schedule_filename)).to eq(processed_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it "still applies the template during a normal update" do
      subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: false, debug: false)

      expected_next_day = processed_next_day.sub('- existing next day', "- template task\n- existing next day")
      expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it "still requires a work-hour marker when no template is applied" do
      schedule_without_marker = schedule.sub("#LPIM_REPLACE\n", '')
      File.write(schedule_filename, schedule_without_marker)

      expect {
        subject.update(schedule_filename, archive_filename, template_filename: nil, compare: false, skips_only: false, debug: false)
      }.to raise_error('No replacement or insertion point found!')

      expect(File.read(schedule_filename)).to eq(schedule_without_marker)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "keeps skips-only updates from archiving the current day" do
      File.write(schedule_filename, schedule.sub('(replan 1)', '(replan s 1)'))

      subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: true, debug: false)

      expected_current_day = current_day.sub("- daily task (replan 1)\n", '')
      expected_next_day = next_day.sub("-----\n", "- daily task (replan 1)\n-----\n")
      expect(File.read(schedule_filename)).to eq(expected_current_day + expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end
  end
end
