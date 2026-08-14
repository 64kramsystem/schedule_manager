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

  it 'removes template top flags without changing other carets' do
    content = <<~TEXT
      +^ top
        -^ nested
      S^ qualifier
      +^no-space
      - caret ^ in description

    TEXT

    expect(subject.execute(content)).to eq(<<~TEXT)
      + top
        - nested
      S qualifier
      +^no-space
      - caret ^ in description

    TEXT
  end
end
