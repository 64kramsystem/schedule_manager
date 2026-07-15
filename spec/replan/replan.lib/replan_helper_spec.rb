require 'date'
require 'rspec'

require_relative '../../../replan.lib/replan_helper.rb'

describe ReplanHelper do
  let(:helper) { Class.new { extend ReplanHelper } }

  it "should add a new date section" do
    source_content = <<~TXT
          SUN 11/JUL/2021
      - foobar

    TXT

    expected_content = <<~TXT
      #{source_content.chomp}
          MON 12/JUL/2021
      -----
      -----
      -----
      -----

    TXT

    actual_content = helper.add_new_date_section(source_content, Date.new(2021, 7, 11), Date.new(2021, 7, 12))

    expect(actual_content).to eql(expected_content)
  end

  context "find_date_section, section not found" do
    it "should raise an error by default" do
      source_content = "nothing!"

      expect {
        helper.find_date_section(source_content, Date.today)
      }.to raise_error(/^Section not found for date: /)
    end

    it "should allow sections without separators" do
      source_content = <<~TXT
            SUN 11/JUL/2021
        - foobar

      TXT

      expect {
        helper.find_date_section(source_content, Date.new(2021, 7, 11))
      }.not_to raise_error
    end

    it "should raise an error if a section has separators, but doesn't end with one" do
      source_content = <<~TXT
            SUN 11/JUL/2021
        -----
        -----
        -----
        -----
        - foobar

      TXT

      expect {
        helper.find_date_section(source_content, Date.new(2021, 7, 11))
      }.to raise_error("Date `2021-07-11` section doesn't end with a separator!")
    end

    # Although this concept has some operational overlap with the former (both can happen is a section
    # is accidentally split in two), this is the semantically specific one.
    # The former can be considered as covering the separators correctness rather than the section
    # divisions; in particular, it doesn't cover the case where a day has no spearators, and it's accidentally
    # split in two.
    #
    it "should raise an error when a section is accidentally split in two" do
      source_content = <<~TXT
            SUN 11/JUL/2021
        - foo

        - bar

      TXT

      expect {
        helper.find_date_section(source_content, Date.new(2021, 7, 11))
      }.to raise_error('The header after date 2021-07-11 is not a correct date header: "- bar"')
    end

    it "should not raise an error if :allow_not_found is specified" do
      source_content = "nothing!"

      expect(helper.find_date_section(source_content, Date.today, allow_not_found: true)).to be(nil)
    end
  end # context "find_date_section"

  context "#ensure_trailing_blank_line" do
    it "should append a blank line when the last section isn't terminated by one" do
      source_content = "    FRI 24/NOV/2028\n% event (replan 3y)\n-----\n-----\n-----\n-----\n"

      expect(helper.ensure_trailing_blank_line(source_content)).to eql(source_content + "\n")
    end

    it "should leave content already terminated by a blank line unchanged" do
      source_content = "    FRI 24/NOV/2028\n-----\n-----\n-----\n-----\n\n"

      expect(helper.ensure_trailing_blank_line(source_content)).to eql(source_content)
    end
  end

  context "#verify_date_section_header_after" do
    it "should recognize the end-of-schedule separator" do
      source_content = <<~TXT
            SUN 11/JUL/2021
        - foo

        -------------------------------------------------------------------------------

        barbar
      TXT

      result = helper.verify_date_section_header_after(source_content, Date.new(2021, 7, 11))

      expect(result).to be(nil)
    end
  end
end # describe ReplanHelper
