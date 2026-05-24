require 'English'

# Copy children from snap-file sections into matching schedule placeholders.
#
class Resnapper
  SNAP_REFERENCE_REGEX = /\{\{@(.+?)\}\}/
  SNAP_SECTION_HEADER_REGEX = /^## (.+)$/

  # snap: String (filename) or IO (content).
  #
  def initialize(snap)
    @snap = snap.respond_to?(:read) ? snap.read : IO.read(snap)
    @sections = parse_sections
  end

  def self.snap_reference?(content)
    content.match?(SNAP_REFERENCE_REGEX)
  end

  def execute(content)
    lines = content.lines(chomp: true)
    keep_final_newline = content.end_with?("\n")

    edited_lines = lines.each_with_index.flat_map do |line, i|
      next [line] if line !~ SNAP_REFERENCE_REGEX

      reference = $LAST_MATCH_INFO[1]

      if next_line_has_children?(line, lines[i + 1])
        [line]
      else
        [line] + indented_children(reference, line)
      end
    end

    edited_content = edited_lines.join("\n")
    edited_content += "\n" if keep_final_newline
    edited_content
  end

  private

  def parse_sections
    sections = {}
    section_name = nil
    section_lines = []

    @snap.each_line(chomp: true) do |line|
      if line =~ SNAP_SECTION_HEADER_REGEX
        sections[section_name] = strip_blank_lines(section_lines) if section_name
        section_name = $LAST_MATCH_INFO[1]
        section_lines = []
      elsif section_name
        section_lines << line
      end
    end

    sections[section_name] = strip_blank_lines(section_lines) if section_name

    sections
  end

  def strip_blank_lines(lines)
    lines = lines.dup

    lines.shift while lines.first&.strip == ''
    lines.pop while lines.last&.strip == ''

    lines
  end

  def next_line_has_children?(line, next_line)
    next_line && indentation_size(next_line) > indentation_size(line)
  end

  def indented_children(reference, line)
    children = @sections[reference] || raise("Snap section not found: #{reference}")
    child_indentation = indentation(line) + '  '

    children.map do |child|
      child.empty? ? child : child_indentation + child
    end
  end

  def indentation(line)
    line[/^ */]
  end

  def indentation_size(line)
    indentation(line).size
  end
end
