require 'rspec'
require 'stringio'

require_relative '../../../replan.lib/retemplater.rb'

describe Retemplater do
  let(:current_day) {
    <<~TXT
          SAT 10/JUL/2021
      -----
      -----
      -----
      -----
    TXT
  }

  # Returning a StringIO makes things confusing, due to the cursor positioning on R/W.
  #
  let(:template) {
    <<~TXT
      -----
      - bar1
      -----
      - baz1
      -----
      - qux1
      -----
    TXT
  }

  it "Should fill the next day with the template" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      - foo0
      -----
      - bar0
      -----
      - baz0
      -----
      -----

    TXT

    # Terminating blank lines test the normalization.
    #
    padded_template = template + "\n\n"

    expected_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      - foo0
      -----
      - bar0
      - bar1
      -----
      - baz0
      - baz1
      -----
      - qux1
      -----

    TXT

    actual_content = described_class.new(StringIO.new(padded_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "adds children of matching top-level entries to the existing entry in the same time bracket" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      S day qualifier
      - shared entry
        - existing child
        - repeated child
      - following existing entry
      -----
      - other entry
      -----
      -----
      -----

    TXT

    matching_template = <<~TXT
      -^ shared entry
        -^ template child
          - template grandchild
        - repeated child
      - following template entry
      -----
      - other entry
      - shared entry
        - child in another bracket
      -----
      -----
      -----
    TXT

    expected_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      S day qualifier
      - shared entry
        - existing child
        - repeated child
        - template child
          - template grandchild
        - repeated child
      - following existing entry
      - following template entry
      -----
      - other entry
      - shared entry
        - child in another bracket
      -----
      -----
      -----

    TXT

    actual_content = described_class.new(StringIO.new(matching_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "Should add caret-suffixed template events to the top of their time bracket" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      - existing morning
      -----
      - existing noon
      -----
      -----
      -----

    TXT

    caret_template = <<~TXT
      -^ first morning
      -^ second morning
      - last morning
      -----
      -^ first noon
        - nested detail
      - last noon
      -----
      -----
      -----
    TXT

    expected_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      - first morning
      - second morning
      - existing morning
      - last morning
      -----
      - first noon
        - nested detail
      - existing noon
      - last noon
      -----
      -----
      -----

    TXT

    actual_content = described_class.new(StringIO.new(caret_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "Should add indented plus caret events and their descendants to the top" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      -----
      - existing noon
      -----
      -----
      -----

    TXT

    caret_template = <<~TXT
      -----
        +^ lunch, floss.s, teeth
          +^ prep water
        + regular indented entry
      -----
      -----
      -----
    TXT

    expected_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      -----
        + lunch, floss.s, teeth
          + prep water
      - existing noon
        + regular indented entry
      -----
      -----
      -----

    TXT

    actual_content = described_class.new(StringIO.new(caret_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  ['S', '%'].each do |day_event_qualifier|
    it "Should leave the #{day_event_qualifier} day event qualifier at the top" do
      source_content = <<~TXT
        #{current_day}

            SUN 11/JUL/2021
        #{day_event_qualifier} day event
          - nested detail
        - existing morning
        -----
        -----
        -----
        -----

      TXT

      caret_template = <<~TXT
        -^ first morning
        -----
        -----
        -----
        -----
      TXT

      expected_content = <<~TXT
        #{current_day}

            SUN 11/JUL/2021
        #{day_event_qualifier} day event
          - nested detail
        - first morning
        - existing morning
        -----
        -----
        -----
        -----

      TXT

      actual_content = described_class.new(StringIO.new(caret_template)).execute(source_content)

      expect(actual_content).to eql(expected_content)
    end
  end

  it "Should fill the missing separators" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      -----
      -----
      -----

    TXT

    expected_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      -----
      - bar1
      -----
      - baz1
      -----
      - qux1
      -----

    TXT

    actual_content = described_class.new(StringIO.new(template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  it "Should raise an error if too many time brackets are found" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      -----
      -----
      -----
      -----
      -----

    TXT

    expect {
      described_class.new(StringIO.new(template)).execute(source_content)
    }.to raise_error("Date `2021-07-11` section has too many separators (5)!")
  end

  it "Should raise an error if the next date header is invalid (e.g. there is an unexpected space)" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      - foo

      -----
      -----
      -----
      -----

          MON 12/JUL/2021
      - foo

    TXT

    # Without this error checking, it results in this:
    #
    #     -----
    #     -----
    #     -----
    #     -----
    #
    #
    #     -----
    #     - bar1
    #     -----
    #     - baz1
    #     -----
    #     - qux1
    #     -----
    #
    #     -----
    #     -----
    #     -----
    #     -----
    #
    expect {
      described_class.new(StringIO.new(template)).execute(source_content)
    }.to raise_error('The header after date 2021-07-11 is not a correct date header: "-----"')
  end
end # describe Retemplater
