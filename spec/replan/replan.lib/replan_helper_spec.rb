require 'date'
require 'rspec'

require_relative '../../../replan.lib/replan_helper.rb'

# Very basic.
#
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

    it "should not raise an error if :allow_not_found is specified" do
      source_content = "nothing!"

      expect(helper.find_date_section(source_content, Date.today, allow_not_found: true)).to be(nil)
    end
  end # context "find_date_section"
end # describe ReplanHelper
