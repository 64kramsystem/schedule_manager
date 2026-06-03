require 'rspec'

require_relative '../../../replan.lib/readder.rb'

describe Readder do
  it "should add headers for the missing days within the given range" do
    source_content = <<~TXT
          MON 20/SEP/2021
      - foo

          WED 22/SEP/2021
      - bar

    TXT

    expected_content = <<~TXT
          MON 20/SEP/2021
      - foo

          TUE 21/SEP/2021
      -----
      -----
      -----
      -----

          WED 22/SEP/2021
      - bar

    TXT

    actual_content = subject.execute(source_content, days: 2)

    expect(actual_content).to eql(expected_content)
  end

  it "should not duplicate already existing date sections" do
    source_content = <<~TXT
          MON 20/SEP/2021
      - foo

          TUE 21/SEP/2021
      - bar

          WED 22/SEP/2021
      - baz

    TXT

    actual_content = subject.execute(source_content, days: 2)

    expect(actual_content).to eql(source_content)
  end
end # describe Readder
