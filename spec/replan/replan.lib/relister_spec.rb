require 'rspec'
require 'date'

require_relative '../../../replan.lib/relister.rb'

RSpec::Matchers.define_negated_matcher :succeed, :raise_error

module RelisterSpecHelper
  def header(date)
    date.strftime('%a %d/%b/%Y').upcase
  end

  def json(date)
    date.strftime("%F")
  end
end

# WATCH OUT! Pay attention to the start date (e.g. `Date.today + 1` for the regular mode`).
#
describe Relister do
  include RelisterSpecHelper

  # Close to the week change - trickier case :)
  #
  let(:reference_date) { Date.new(2022, 10, 8) }

  # Make sure that the symbols include the initial of the :reference_date day name (see disambiguation
  # UT).
  #
  let(:subject) { described_class.new('!*S') }

  around :each do |example|
    Timecop.freeze(reference_date) do
      example.run
    end
  end

  it "Should allow missing dates (sections)" do
    test_content = <<~TXT
          #{header(reference_date + 1)}
      - test (replan 1)

    TXT

    expect {
      subject.execute(test_content, export: false)
    }.not_to raise_error
  end

  it "Should disambiguate event letter symbols from headers" do
    test_content = <<~TXT
          #{header(reference_date + 1)}
      * event
      S event2

    TXT

    expected_output = test_content + "=====\n\n"

    expect {
      subject.execute(test_content, export: false)
    }.to succeed.and output(expected_output).to_stdout
  end

  it "Should not print the separator if the first event is after the first day" do
    test_content = <<~TXT
          #{header(reference_date + 1)}

          #{header(reference_date + 2)}
      * some event

    TXT

    expected_output = <<~TXT
          #{header(reference_date + 2)}
      * some event

    TXT

    expect {
      subject.execute(test_content, export: false)
    }.to output(expected_output).to_stdout
  end

  it "Should output in JSON format" do
    first_date = reference_date - 1
    second_date = reference_date
    third_date = reference_date + 365

    test_content = <<~TXT
          #{header(first_date)}
      * foo event [a note] bar [another note]
      * bar other (kept note)

          #{header(second_date)}
      * qux event

          #{header(third_date)}
      ! happy day
      * baz event

    TXT

    expected_output = JSON.pretty_generate([
      {"date": json(first_date),  "title": "foo event bar", "type": "*"},
      {"date": json(first_date),  "title": "bar other (kept note)", "type": "*"},
      {"date": json(second_date), "title": "qux event", "type": "*"},
      {"date": json(third_date), "title": "happy day", "type": "!"},
      {"date": json(third_date), "title": "baz event", "type": "*"},
    ])

    expect {
      subject.execute(test_content, export: first_date)
    }.to output(expected_output).to_stdout
  end

  it "Should allow non-replan `*` lines" do
    test_content = <<~TXT
          #{header(reference_date + 1)}
      * some event
      * other event (replan 1)

    TXT

    expected_output = <<~TXT
          #{header(reference_date + 1)}
      * some event
      * other event

      =====

    TXT

    expect {
      subject.execute(test_content, export: false)
    }.to output(expected_output).to_stdout
  end
end # describe Relister
