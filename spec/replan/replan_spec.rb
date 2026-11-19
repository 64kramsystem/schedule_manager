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
      - template task
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
      File.write(schedule_filename, current_day.sub('- daily task', "-----\n- daily task"))
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
          expect(stderr.gets).to include('ERROR:', 'too many separators')
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

  describe '#list' do
    it 'exports events after temporary blank lines without rewriting the schedule' do
      content = current_day.sub('- work 2h', "\n* visible event\n\n- work 2h")
      File.write(schedule_filename, content)
      File.write(archive_filename, '')

      expect {
        subject.list(schedule_filename, archive_filename, '*', export: Date.new(2021, 9, 20))
      }.to output(JSON.pretty_generate([{date: '2021-09-20', title: 'visible event', type: '*'}])).to_stdout

      expect(File.read(schedule_filename)).to eq(content)
    end
  end

  describe '#apply_template' do
    it 'ignores temporary blank lines in the selected date' do
      File.write(schedule_filename, schedule.sub('- existing selected day', "\n- existing selected day"))

      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expect(File.read(schedule_filename)).to eq(schedule.sub('- existing selected day', "- existing selected day\n- template task"))
    end

    it "preserves literal backslashes through template insertion" do
      task = %q{repla\n \0 \&}
      File.write(template_filename, template.sub('template task') { task })

      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expected = schedule.sub('- existing selected day') { |existing| "#{existing}\n- #{task}" }
      expect(File.read(schedule_filename)).to eq(expected)
    end

    it "changes only the selected date and leaves current-day work and the archive untouched" do
      subject.apply_template(schedule_filename, template_filename:, day: Date.new(2021, 9, 22), compare: false)

      expected_day = <<~TXT
            WED 22/SEP/2021
        - existing selected day
        - template task
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

      expect(File.read(schedule_filename)).to eq(schedule.sub('- existing selected day', "- existing selected day\n- template task"))
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
    let(:daily_template_filename) { File.join(@directory, '__daily.txt') }

    before do
      File.write(daily_template_filename, '')
    end

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

    it 'expands references from the templates directory when the selected template is disabled' do
      File.write(File.join(@directory, 'tasks.txt'), "+ first\n  - nested\n")
      File.write(schedule_filename, schedule.sub('- existing next day', '- {{@tasks}}'))

      subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)

      expect(File.read(schedule_filename)).to include("- tasks\n  + first\n    - nested\n")
    end

    ['', '-'].each do |suffix|
      it "archives the expanded {{@tasks#{suffix}}} occurrence and replans the reference" do
        reference = "+ {{@tasks#{suffix}}} (replan p tue)"
        File.write(File.join(@directory, 'tasks.txt'), "+ first\n  - nested\n")
        File.write(schedule_filename, schedule.sub('- work 2h', "- weekly tasks\n  #{reference}\n- work 2h"))

        subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)

        archived_tasks = suffix.empty? ? "  + tasks\n    + first\n      - nested\n" : "  + first\n    - nested\n"
        expected_archived_day = archived_day.sub('- work 2h', "- weekly tasks\n#{archived_tasks}- work 2h")
        expected_next_day = processed_next_day.sub("-----\n", "- weekly tasks\n  #{reference}\n-----\n")
        expect(File.read(archive_filename)).to eq(expected_archived_day + "Existing archive\n")
        expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
      end
    end

    it 'replans tasks imported while expanding the current occurrence' do
      File.write(File.join(@directory, 'tasks.txt'), "+ imported task (replan 1)\n")
      File.write(schedule_filename, schedule.sub('- work 2h', "- weekly tasks\n  + {{@tasks-}} (replan p tue)\n- work 2h"))

      subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)

      expect(File.read(archive_filename)).to include("- weekly tasks\n  + imported task\n")
      expect(File.read(schedule_filename)).to include("- weekly tasks\n  + {{@tasks-}} (replan p tue)\n  + imported task (replan 1)\n")
    end

    it 'processes all tasks and archives the current day despite temporary blank lines' do
      File.write(schedule_filename, schedule.sub('- work 2h', "\n\n- work 2h"))

      subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)

      expect(File.read(schedule_filename)).to eq(processed_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it "preserves literal backslashes in replanned tasks" do
      task = %q{repla\n \0 \&}
      File.write(schedule_filename, schedule.sub('daily task') { task })

      subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)

      expected_next_day = processed_next_day.sub('daily task') { task }
      expected_archived_day = archived_day.sub('daily task') { task }
      expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(expected_archived_day + "Existing archive\n")
    end

    it "applies __daily.txt and archives the current day when the selected template is disabled" do
      File.write(daily_template_filename, "- existing next day\n  - daily child\n")

      subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)

      expected_next_day = processed_next_day.sub('- existing next day', "- existing next day\n  - daily child")
      expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it "merges __daily.txt after the selected template supplies its parent" do
      File.write(daily_template_filename, "- template task|missing\n  - daily child\n")

      subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: false, debug: false)

      expected_next_day = processed_next_day.sub('- daily task', "- template task\n  - daily child\n- daily task")
      expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq(archived_day + "Existing archive\n")
    end

    it 'merges __daily.txt once when it is the selected template' do
      File.write(daily_template_filename, "- existing next day\n  - daily child\n")
      selected_template = File.join(@directory, './__daily.txt')

      subject.update(schedule_filename, archive_filename, template_filename: selected_template, templates_directory: @directory, compare: false, skips_only: false, debug: false)

      expected_next_day = processed_next_day.sub('- existing next day', "- existing next day\n  - daily child")
      expect(File.read(schedule_filename)).to eq(expected_next_day + selected_day)
    end

    it 'stops before saving if __daily.txt is missing' do
      File.delete(daily_template_filename)

      expect {
        subject.update(schedule_filename, archive_filename, template_filename:, compare: false, skips_only: false, debug: false)
      }.to raise_error(Errno::ENOENT, /__daily\.txt/)

      expect(File.read(schedule_filename)).to eq(schedule)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "still requires a work-hour marker when the selected template is disabled" do
      schedule_without_marker = schedule.sub("#LPIM_REPLACE\n", '')
      File.write(schedule_filename, schedule_without_marker)

      expect {
        subject.update(schedule_filename, archive_filename, template_filename: nil, templates_directory: @directory, compare: false, skips_only: false, debug: false)
      }.to raise_error('No replacement or insertion point found!')

      expect(File.read(schedule_filename)).to eq(schedule_without_marker)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end

    it "keeps skips-only updates from archiving the current day" do
      File.write(schedule_filename, schedule.sub('(replan 1)', '(replan s 1)'))
      File.write(daily_template_filename, "- existing next day\n  - daily child\n")

      subject.update(schedule_filename, archive_filename, template_filename:, templates_directory: @directory, compare: false, skips_only: true, debug: false)

      expected_current_day = current_day.sub("- daily task (replan 1)\n", '')
      expected_next_day = next_day.sub("-----\n", "- daily task (replan 1)\n-----\n")
      expect(File.read(schedule_filename)).to eq(expected_current_day + expected_next_day + selected_day)
      expect(File.read(archive_filename)).to eq("Existing archive\n")
    end
  end
end
