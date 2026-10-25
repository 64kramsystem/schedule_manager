require 'rspec'

require_relative '../../../replan.lib/cleaner.rb'

describe Cleaner do
  it 'removes temporary blank lines within days while preserving section boundaries' do
    content = "    MON 07/JUN/2021\n- first\n\n- second\n\n\n-----\n\n    TUE 08/JUN/2021\n- third\n\n"

    expected = "    MON 07/JUN/2021\n- first\n- second\n-----\n\n    TUE 08/JUN/2021\n- third\n\n"
    expect(subject.execute(content)).to eq(expected)
  end

  it 'preserves blank lines outside the schedule and before its end separator' do
    content = "Preamble\n\n    MON 07/JUN/2021\n- task\n\n#{ReplanHelper::END_OF_SCHEDULE_SEPARATOR}\n\nNotes\n\nMore notes\n\n"

    expect(subject.execute(content)).to eq(content)
  end

  it 'removes blank lines exposed by temporary separator cleanup' do
    content = "    MON 07/JUN/2021\n- first\n\n~\n\n- second\n\n"

    expect(subject.execute(content)).to eq("    MON 07/JUN/2021\n- first\n- second\n\n")
  end

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
