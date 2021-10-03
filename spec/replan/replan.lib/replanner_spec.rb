require 'rspec'
require 'timecop'

require_relative '../../../replan.lib/replanner.rb'

module ReplannerSpecHelper
  BASE_DATE = Date.new(2021, 9, 20)

  # :date_stub_data format is {date_arg: new_date}; :date_arg is the argument received by Date, which
  #   cause stubbing with :new_date.
  #
  def assert_replan(test_content, expected_next_date_section, date_stub_data)
    raise ":date_stub_data must have a size of 1" if date_stub_data.size != 1

    date_arg = date_stub_data.keys.first
    new_date = date_stub_data.values.first

    allow(Date).to receive(:parse).and_wrap_original do |m, *args|
      args == [date_arg] ? new_date : m.call(*args)
    end

    result = Timecop.freeze(BASE_DATE) do
      subject.execute(test_content)
    end

    expect(result).to include(expected_next_date_section)
  end
end

describe Replanner do
  include ReplannerSpecHelper

  before :all do
    raise "Remove the Date.parse stubbing!" if Gem.loaded_specs['timecop'].version >= Gem::Version.new('0.10')
  end

  it "Should replan a 10+ 'm' date" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo (replan 10m)

    TXT

    expected_updated_content = <<~TXT
        SUN 17/JUL/2022
    - foo (replan 10m)
    TXT

    assert_replan(test_content, expected_updated_content, 2 => Date.new(2021, 9, 22))
  end

  it "Should add the replanned lines to the same time bracket as the original" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo1 (replan 7)
    -----
    - foo1 (replan 7)
    - foo2 (replan 7)
    -----
    - foo3 (replan 7)
    -----
    - foo4 (replan 7)
    -----

        MON 27/SEP/2021
    - bar1
    -----
    - bar2
    -----
    -----
    - bar4
    -----

    TXT

    expected_updated_content = <<~TXT
        MON 27/SEP/2021
    - foo1 (replan 7)
    - bar1
    -----
    - foo1 (replan 7)
    - foo2 (replan 7)
    - bar2
    -----
    - foo3 (replan 7)
    -----
    - foo4 (replan 7)
    - bar4
    -----
    TXT

    assert_replan(test_content, expected_updated_content, 2 => Date.new(2021, 9, 22))
  end

  it "Should add missing brackets, when adding replan lines" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo1 (replan 7)
    -----
    - foo1 (replan 7)
    -----
    -----
    -----

        MON 27/SEP/2021
    - foo

    TXT

    expected_updated_content = <<~TXT
        MON 27/SEP/2021
    - foo1 (replan 7)
    - foo
    -----
    - foo1 (replan 7)
    -----
    -----
    -----
    TXT

    assert_replan(test_content, expected_updated_content, 2 => Date.new(2021, 9, 22))
  end

  context "Interpolations" do
    it "Should apply {{date}}" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo ()(xxx){{date}} (replan 2)

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      - foo ()(xxx)

          WED 22/SEP/2021
      - foo ()(mon/20){{date}} (replan 2)
      TXT

      assert_replan(test_content, expected_updated_content, 2 => Date.new(2021, 9, 22))
    end
  end

  context "skip" do
    it "Should skip a replan" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan s 2)

      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - foo (replan 2)
      TXT

      assert_replan(test_content, expected_next_date_section, 2 => Date.new(2021, 9, 22))
    end

    it "Should skip an update, without updating the line" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan su 2)

      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - foo (replan u 2)
      TXT

      expect_any_instance_of(InputHelper)
        .not_to receive(:ask)

      assert_replan(test_content, expected_next_date_section, 'wed' => Date.new(2021, 9, 22))
    end

    it "Should skip an update full, without updating the line" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan sU wed)

      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - foo (replan U wed)
      TXT

      expect_any_instance_of(InputHelper)
        .not_to receive(:ask)

      assert_replan(test_content, expected_next_date_section, 'wed' => Date.new(2021, 9, 22))
    end
  end # context "skip"

  context "timestamp handling" do
    it "Should remove the timestamp, if there isn't a fixed one" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo (replan 2)

      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo

          WED 22/SEP/2021
      - foo (replan 2)
      TXT

      assert_replan(test_content, expected_next_date_section, 2 => Date.new(2021, 9, 22))
    end

    context "fixed timestamp" do
      it "Should copy the timestamp from line time, if it's the only one" do
        # This is a variation of the standard time description, which is useful for intervals.
        #
        test_content = <<~TXT
            MON 20/SEP/2021
        - 12:30-13:00. foo (replan f 2)

        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - 12:30-13:00. foo

            WED 22/SEP/2021
        - 12:30-13:00. foo (replan f 2)
        TXT

        assert_replan(test_content, expected_next_date_section, 2 => Date.new(2021, 9, 22))
      end

      it "Should copy the timestamp from replan time, if it's the only one" do
        # This is a variation of the standard time description, which is useful for intervals.
        #
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan f12:00 2)

        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - foo

            WED 22/SEP/2021
        - 12:00. foo (replan f 2)
        TXT

        assert_replan(test_content, expected_next_date_section, 2 => Date.new(2021, 9, 22))
      end

      it "Should give priority to the replan timestamp" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - 12:30. foo (replan f14:00 2)

        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - 12:30. foo

            WED 22/SEP/2021
        - 14:00. foo (replan f 2)
        TXT

        assert_replan(test_content, expected_next_date_section, 2 => Date.new(2021, 9, 22))
      end

      it "Should require a timestamp" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan f 2)

        TXT

        expect { subject.execute(test_content) }.to raise_error('Fixed timestamp is set, but no timestamp is provided: "- foo (replan f 2)"')
      end
    end # context "fixed timestamp"
  end # context "timestamp handling"

  context 'next' do
    context 'field weekday support' do
      it "Should raise an error if not updating full" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan sun)

        TXT

        expect {
          subject.execute(test_content, true)
        }.to raise_error("Weekdays are allowed on with a full update")
      end

      # "current" is intended the european way.
      #
      it "Should set the day in the current week, accounting the semantic different with Ruby's start of the week" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan U sun)

        TXT

        # This also ensures that the picked Sunday is the following one.
        #
        expected_next_date_section = <<~TXT
            SUN 26/SEP/2021
        - foo
        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U sun)")
          .and_return("foo (replan U sun)")

        assert_replan(test_content, expected_next_date_section, 'sun' => Date.new(2021, 9, 26))
      end

      it "Should set the day in the following week, when the weekday matches the current day" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan U mon)

        TXT

        expected_next_date_section = <<~TXT
            MON 27/SEP/2021
        - foo
        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U mon)")
          .and_return("foo (replan U mon)")

        assert_replan(test_content, expected_next_date_section, 'mon' => Date.new(2021, 9, 27))
      end

      it "Should add one week, when the day is in the current week" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan sun+)

        TXT

        expected_next_date_section = <<~TXT
            SUN 03/OCT/2021
        - foo
        TXT

        assert_replan(test_content, expected_next_date_section, 'sun' => Date.new(2021, 9, 26))
      end

      # In order to avoid confusion, the `+` always add one week.
      #
      it "Should add one week, when the day is in the next week" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan mon+)

        TXT

        expected_next_date_section = <<~TXT
            MON 04/OCT/2021
        - foo
        TXT

        assert_replan(test_content, expected_next_date_section, 'mon' => Date.new(2021, 9, 27))
      end

      it "Should consider the event recurring, if it's update full with interval" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan U 2)

        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - foo

            WED 22/SEP/2021
        - bar (replan U 2)
        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U 2)")
          .and_return("bar (replan U 2)")

        assert_replan(test_content, expected_next_date_section, 2 => Date.new(2021, 9, 22))
      end

      it "Should consider the event recurring, if it's update full with weekday but not interval" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan U sun)

        TXT

        expected_next_date_section = <<~TXT
            WED 22/SEP/2021
        - bar (replan U wed)
        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U sun)")
          .and_return("bar (replan U wed)")

        assert_replan(test_content, expected_next_date_section, 'wed' => Date.new(2021, 9, 22))
      end
    end # context 'weekday support'

    it "Should copy an update full with interval and numeric next" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan U 3 in 2)

      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - foo

          WED 22/SEP/2021
      - foo (replan U 3 in 2)
      TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U 3 in 2)")
          .and_return("foo (replan U 3 in 2)")

      assert_replan(test_content, expected_next_date_section, '2' => Date.new(2021, 9, 22))
    end
  end # context 'next'
end # describe Replanner
