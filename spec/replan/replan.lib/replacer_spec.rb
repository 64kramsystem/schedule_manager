require 'rspec'

require_relative '../../../replan.lib/replacer'

describe Replacer do
  def section(*lines)
    "    MON 20/SEP/2021\n#{lines.join("\n")}\n\n"
  end

  [
    %q{'repla\n -t'},
    %q{"repla\n -t"},
    %q{/repla\\\\n -[a-z]/},
  ].each do |matcher|
    it "replaces a command in its existing position using #{matcher}" do
      content = section(
        '; before',
        '; repla\n -t',
        '; after',
        "; {{replace #{matcher}}} lpim sync && repla\\n -t",
      )
      expected = section('; before', '; lpim sync && repla\n -t', '; after')

      expect(subject.execute(content)).to eq(expected)
    end
  end

  it 'matches quoted strings literally rather than as regexes' do
    content = section('- a.b', '- axb', %q{- {{replace 'a.b'}} replacement})

    expect(subject.execute(content)).to eq(section('- replacement', '- axb'))
  end

  it 'supports escaped delimiters in both quoted string forms' do
    content = section(
      %q{- it's ready},
      '- say "ready"',
      %q{- {{replace 'it\'s'}} first replacement},
      %q{- {{replace "say \"ready\""}} second replacement},
    )

    expect(subject.execute(content)).to eq(section('- first replacement', '- second replacement'))
  end

  it 'supports regex anchors and escaped slashes' do
    content = section('- path/to/12', %q{- {{replace /^- path\/to\/\d+$/}} replacement})

    expect(subject.execute(content)).to eq(section('- replacement'))
  end

  it 'counts matching lines rather than occurrences within a line' do
    content = section('- target target', '- {{replace /target/}} replacement')

    expect(subject.execute(content)).to eq(section('- replacement'))
  end

  it 'does not use a matching line from another date' do
    content = section('- target') +
      section('- {{replace "target"}} replacement').sub('MON 20', 'TUE 21')

    expect {
      subject.execute(content)
    }.to raise_error(/Replace on 2021-09-21 requires exactly one matching line; found 0/)
  end

  it 'does not count directive lines as matching targets' do
    content = section('- {{replace "target"}} target')

    expect {
      subject.execute(content)
    }.to raise_error(/requires exactly one matching line; found 0/)
  end

  it 'rejects multiple matching lines' do
    content = section('- target', '- other target', '- {{replace /target/}} replacement')

    expect {
      subject.execute(content)
    }.to raise_error(/requires exactly one matching line; found 2/)
  end

  it 'does not match text removed by an earlier replacement' do
    content = section('- target', '- {{replace "target"}} first', '- {{replace "target"}} second')

    expect {
      subject.execute(content)
    }.to raise_error(/requires exactly one matching line; found 0/)
  end

  it 'matches the current text after earlier replacements' do
    content = section('- target', '- {{replace "target"}} first', '- {{replace "first"}} second')

    expect(subject.execute(content)).to eq(section('- second'))
  end

  it 'does not treat separators as replacement targets' do
    content = section('~~~~~', '~', '=', '- {{replace /^[~=-]+$/}} replacement', *Array.new(4, '-----'))

    expect {
      subject.execute(content)
    }.to raise_error(/requires exactly one matching line; found 0/)
  end

  it 'rejects malformed directives' do
    content = section('- target', '- {{replace target}} replacement')

    expect {
      subject.execute(content)
    }.to raise_error(/Invalid replace directive on 2021-09-20/)
  end

  it 'rejects invalid regexes' do
    content = section('- target', '- {{replace /[/}} replacement')

    expect { subject.execute(content) }.to raise_error(RegexpError)
  end
end
