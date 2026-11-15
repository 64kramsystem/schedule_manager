require 'rspec'
require 'tmpdir'

require_relative '../../../replan.lib/resnapper.rb'

describe Resnapper do
  around do |example|
    Dir.mktmpdir do |directory|
      @templates_directory = directory
      File.write(File.join(directory, 'section A.txt'), "\n+ foo\n+ bar\n  * bar.1\n  + bar.2\n\n")
      File.write(File.join(directory, 'section B.txt'), "o baz\n- qux\n")
      example.run
    end
  end

  it "Should insert children when none are present" do
    source_content = <<~TXT
          MON 20/SEP/2021
      -----
      - {{@section A}}
      -----
      -----
      -----
    TXT

    expected_content = <<~TXT
          MON 20/SEP/2021
      -----
      - {{@section A}}
        + foo
        + bar
          * bar.1
          + bar.2
      -----
      -----
      -----
    TXT

    actual_content = described_class.new(@templates_directory).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "Should skip references that already have children" do
    source_content = <<~TXT
          MON 20/SEP/2021
      -----
      - {{@section A}}
        + already present
      -----
      -----
      -----
    TXT

    actual_content = described_class.new(@templates_directory).execute(source_content)

    expect(actual_content).to eql(source_content)
  end

  it "does not insert children for skip or once references without a current occurrence" do
    source_content = <<~TXT
        MON 20/SEP/2021
    - 09:50. work
      + {{@section A}} (replan s tue)
      % 12:00. olga (replan f10:00 tue in 2w)
        - olga child
      + {{@section B}} (replan o wed)
    TXT

    actual_content = described_class.new(@templates_directory).execute(source_content)

    expect(actual_content).to eql(source_content)
  end

  it "Should handle multiple placeholders across multiple dates" do
    source_content = <<~TXT
          MON 20/SEP/2021
      - {{@section A}}
      -----
      -----
      -----
      -----

          TUE 21/SEP/2021
      -----
      -----
        - {{@section B}}
      -----
      -----
    TXT

    expected_content = <<~TXT
          MON 20/SEP/2021
      - {{@section A}}
        + foo
        + bar
          * bar.1
          + bar.2
      -----
      -----
      -----
      -----

          TUE 21/SEP/2021
      -----
      -----
        - {{@section B}}
          o baz
          - qux
      -----
      -----
    TXT

    actual_content = described_class.new(@templates_directory).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "raises an error if the referenced template file does not exist" do
    source_content = <<~TXT
          MON 20/SEP/2021
      - {{@Missing}}
    TXT

    expect {
      described_class.new(@templates_directory).execute(source_content)
    }.to raise_error("Template file not found: #{File.join(@templates_directory, 'Missing.txt')}")
  end

  it "Should derive indentation from the placeholder line" do
    source_content = <<~TXT
          MON 20/SEP/2021
      -----
          - {{@section A}}
      -----
      -----
      -----
    TXT

    expected_content = <<~TXT
          MON 20/SEP/2021
      -----
          - {{@section A}}
            + foo
            + bar
              * bar.1
              + bar.2
      -----
      -----
      -----
    TXT

    actual_content = described_class.new(@templates_directory).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end
end # describe Resnapper
