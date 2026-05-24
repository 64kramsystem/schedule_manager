require 'rspec'
require 'stringio'

require_relative '../../../replan.lib/resnapper.rb'

describe Resnapper do
  let(:snap_content) {
    <<~TXT
      ## section A

      + foo
      + bar
        * bar.1
        + bar.2

      ## section B

      o baz
      - qux
    TXT
  }

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

    actual_content = described_class.new(StringIO.new(snap_content)).execute(source_content)

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

    actual_content = described_class.new(StringIO.new(snap_content)).execute(source_content)

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

    actual_content = described_class.new(StringIO.new(snap_content)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "Should raise an error if the referenced section doesn't exist in the snap file" do
    source_content = <<~TXT
          MON 20/SEP/2021
      - {{@Missing}}
    TXT

    expect {
      described_class.new(StringIO.new(snap_content)).execute(source_content)
    }.to raise_error("Snap section not found: Missing")
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

    actual_content = described_class.new(StringIO.new(snap_content)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end
end # describe Resnapper
