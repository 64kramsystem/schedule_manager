require 'rspec'

require_relative '../../../replan.lib/replan_helper.rb'
require_relative '../../../replan.lib/refixer.rb'

describe Refixer do
  it "should fix a header whose day word doesn't match the date, leaving correct headers untouched" do
    content = <<~TXT
          TUE 20/SEP/2021
      - foo
          TUE 21/SEP/2021
      - bar

    TXT

    expected_content = <<~TXT
          MON 20/SEP/2021
      - foo
          TUE 21/SEP/2021
      - bar

    TXT

    expect { @actual_content = subject.execute(content) }.to output("- TUE 20/SEP/2021 -> MON\n").to_stdout

    expect(@actual_content).to eql(expected_content)
  end

  it "should return the content unchanged when all headers are correct" do
    content = <<~TXT
          MON 20/SEP/2021
      - foo
          TUE 21/SEP/2021
      - bar

    TXT

    expect { @actual_content = subject.execute(content) }.not_to output.to_stdout

    expect(@actual_content).to eql(content)
  end
end # describe Refixer
