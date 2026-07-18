require 'rspec'

require_relative '../../../replan.lib/cleaner.rb'

describe Cleaner do
  it 'removes standalone temporary separators' do
    content = <<~TEXT
      MON 07/JUN/2021
      - 9:00. work
      ~
      =
      - 10:00. foo

    TEXT

    expect(subject.execute(content)).to eq(<<~TEXT)
      MON 07/JUN/2021
      - 9:00. work
      - 10:00. foo

    TEXT
  end
end
