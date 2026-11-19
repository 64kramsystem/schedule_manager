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

  describe 'environment variables in templates' do
    let(:source_content) { current_day + "\n    SUN 11/JUL/2021\n- existing ${FESTIVAL}\n" + "-----\n" * 4 + "\n" }

    it 'expands template placeholders and preserves existing schedule text' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('FESTIVAL', '${FESTIVAL}').and_return('spring-swing')
      allow(ENV).to receive(:fetch).with('X', '${X}').and_return('')
      template = '- ${FESTIVAL} (a${X}b)' + "\n" + "-----\n" * 4

      actual_content = described_class.new(StringIO.new(template)).execute(source_content)

      expect(actual_content).to eq(source_content.sub('- existing ${FESTIVAL}', "- existing \${FESTIVAL}\n- spring-swing (ab)"))
    end

    it 'keeps unset placeholders and invalid variable names as literal text' do
      unset_name = 'SCHEDULE_MANAGER_TEST_UNSET'
      previous_value = ENV.delete(unset_name)
      line = '- ${SCHEDULE_MANAGER_TEST_UNSET} ${2VAR}'
      template = line + "\n" + "-----\n" * 4

      actual_content = described_class.new(StringIO.new(template)).execute(source_content)

      expect(actual_content).to eq(source_content.sub('- existing ${FESTIVAL}') { |existing| "#{existing}\n#{line}" })
    ensure
      ENV[unset_name] = previous_value
    end
  end

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

  it "fills an explicitly selected date instead of the next day" do
    next_day = <<~TXT
          SUN 11/JUL/2021
      -----
      -----
      -----
      -----

    TXT
    selected_day = <<~TXT
          MON 12/JUL/2021
      - existing
      -----
      -----
      -----
      -----

    TXT
    source_content = current_day + "\n" + next_day + selected_day
    expected_day = <<~TXT
          MON 12/JUL/2021
      - existing
      -----
      - bar1
      -----
      - baz1
      -----
      - qux1
      -----

    TXT

    actual_content = described_class.new(StringIO.new(template)).execute(source_content, date: Date.new(2021, 7, 12))

    expect(actual_content).to eq(current_day + "\n" + next_day + expected_day)
  end

  it "merges matching parents across the day and places new entries in their template bracket" do
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
      - shared entry
        - template child
          - template grandchild
        - repeated child
      - following template entry
      -----
      - other entry
      - shared entry
        - child in another bracket
      - new entry in the second bracket
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
        - child in another bracket
      - following existing entry
      - following template entry
      -----
      - other entry
      - new entry in the second bracket
      -----
      -----
      -----

    TXT

    actual_content = described_class.new(StringIO.new(matching_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  [
    ['- 08:37. work', '- work'],
    ['- work # mega-brogramming', '- work'],
    ['- 08:37. work # mega-brogramming', '- work'],
    ['- 08:37-12:00. work # mega-brogramming', '- work'],
    ['- work', '- 09:00-12:00. work # template comment'],
    ['- 08:37. work # mega-brogramming', '- 09:00. work # template comment'],
  ].each do |existing_parent, template_parent|
    it "merges #{template_parent.inspect} into #{existing_parent.inspect} preserving the existing parent" do
      source_content = <<~TXT
        #{current_day}

            SUN 11/JUL/2021
        #{existing_parent}
          * 10:00. monthly meeting (replan f10:00p +1tue)
        - following existing entry
        -----
        -----
        -----
        -----

      TXT

      matching_template = <<~TXT
        #{template_parent}
          - COFFEE+DAILY OVERVIEW
        -----
        -----
        -----
        -----
      TXT

      expected_content = source_content.sub(
        '- following existing entry',
        "  - COFFEE+DAILY OVERVIEW\n- following existing entry",
      )

      actual_content = described_class.new(StringIO.new(matching_template)).execute(source_content)

      expect(actual_content).to eql(expected_content)
    end
  end

  it "keeps different event symbols and nested parents separate when ignoring timestamps and comments" do
    source_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      + 08:37. work # other symbol
      - other parent
        - 08:37. work # nested entry
      -----
      -----
      -----
      -----

    TXT

    matching_template = <<~TXT
      - work
        - COFFEE+DAILY OVERVIEW
      -----
      -----
      -----
      -----
    TXT

    expected_content = source_content.sub(
      '  - 08:37. work # nested entry',
      "  - 08:37. work # nested entry\n- work\n  - COFFEE+DAILY OVERVIEW",
    )

    actual_content = described_class.new(StringIO.new(matching_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
  end

  describe 'alternative template parents' do
    let(:source_content) do
      current_day + "\n    SUN 11/JUL/2021\n#{morning}-----\n#{noon}-----\n-----\n-----\n\n"
    end
    let(:noon) { '' }
    let(:matching_template) { "- foo|bar\n  - template child\n" + "-----\n" * 4 }

    subject(:retemplater) { described_class.new(StringIO.new(matching_template)) }

    context 'when more than one alternative matches' do
      let(:morning) { "+ foo\n- 09:00. bar # booked\n  - existing child\n" }
      let(:noon) { "- foo\n" }
      let(:matching_template) { "-----\n- foo|bar\n  - template child\n" + "-----\n" * 3 }

      it 'merges into the first matching parent in schedule order' do
        expected = source_content.sub('  - existing child', "  - existing child\n  - template child")

        expect(retemplater.execute(source_content)).to eq(expected)
      end
    end

    context 'when only the second alternative matches in another bracket' do
      let(:morning) { '' }
      let(:noon) { "- bar\n" }

      it 'merges the template children into that parent' do
        expected = source_content.sub('- bar', "- bar\n  - template child")

        expect(retemplater.execute(source_content)).to eq(expected)
      end
    end

    context 'when neither alternative matches a top-level parent on the day' do
      let(:morning) { "+ foo\n- another parent\n  - bar\n" }

      it 'raises an error identifying the template parent' do
        expect { retemplater.execute(source_content) }
          .to raise_error('No matching parent on the selected day for "- foo|bar"')
      end
    end

    context 'when a pipe occurs in a command or comment' do
      let(:morning) { "- foo\n" }
      let(:matching_template) { "- foo # bar|baz\n  - template child\n; echo foo | cat\n" + "-----\n" * 4 }

      it 'preserves the command and matches the parent without its comment' do
        expected = source_content.sub('- foo', "- foo\n  - template child\n; echo foo | cat")

        expect(retemplater.execute(source_content)).to eq(expected)
      end
    end
  end

  describe 'templates without time brackets' do
    let(:source_content) do
      <<~TXT
        #{current_day}

            SUN 11/JUL/2021
        -----
        -----
        - aft-dos
          + existing child
        -----
        - late-dos
        -----

      TXT
    end

    it 'merges children into parents in different brackets' do
      template = "- aft-dos\n  + day-pack\n- late-dos\n  + night-pack"
      expected = source_content
        .sub('  + existing child', "  + existing child\n  + day-pack")
        .sub('- late-dos', "- late-dos\n  + night-pack")

      expect(described_class.new(StringIO.new(template)).execute(source_content)).to eq(expected)
    end

    it 'raises when an unmatched entry has no bracket for placement' do
      template = "- aft-dos\n  + day-pack\n- missing\n  + night-pack\n"

      expect { described_class.new(StringIO.new(template)).execute(source_content) }
        .to raise_error('No matching parent or template bracket for "- missing"')
    end

    it 'finds an existing parent on a day that has no separators' do
      source_content = current_day + "\n    SUN 11/JUL/2021\n- aft-dos\n\n"
      template = "- aft-dos\n  + day-pack\n"
      expected = source_content.chomp + "  + day-pack\n" + "-----\n" * 4 + "\n"

      expect(described_class.new(StringIO.new(template)).execute(source_content)).to eq(expected)
    end
  end

  it "appends template entries to their time brackets and preserves carets as text" do
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
        +^ nested detail
      - last noon
      -----
      -----
      -----
    TXT

    expected_content = <<~TXT
      #{current_day}

          SUN 11/JUL/2021
      - existing morning
      -^ first morning
      -^ second morning
      - last morning
      -----
      - existing noon
      -^ first noon
        +^ nested detail
      - last noon
      -----
      -----
      -----

    TXT

    actual_content = described_class.new(StringIO.new(caret_template)).execute(source_content)

    expect(actual_content).to eql(expected_content)
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
