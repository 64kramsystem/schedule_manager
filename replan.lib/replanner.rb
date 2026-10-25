require_relative 'replan_codec'
require_relative 'replan_helper'
require_relative 'shared_constants'

require 'date'
require 'English'

class Replanner
  include ReplanHelper
  include SharedConstants

  INTERPOLATIONS = {
    %r<[a-z]{3}/\d{2}> => ->(_, curr_date, _, skip) { curr_date.strftime('%a/%d').downcase unless skip}, # "mon/19"
    /(-\d+)/ => ->(match, curr_date, plan_date, skip) do # "-3"
      # Accumulate when skipping; reset otherwise.
      (skip ? match[1].to_i : 0) - (plan_date - curr_date).to_i
    end,
  }

  TIME_BLOCK_BRACKETS = {
    'M' => 0,
    'N' => 1,
    'A' => 2,
    'E' => 3,
  }.freeze
  private_constant :TIME_BLOCK_BRACKETS

  def initialize
    @replan_codec = ReplanCodec.new
  end

  def execute(content, debug: false, skips_only: false)
    dates = find_all_dates(content)

    # Validate the whole schedule before an update can prompt the user. Full updates are checked
    # again below because their new text can introduce skip/once/parent-carry flags.
    #
    dates.each_with_index do |date, date_i|
      replan_lines = find_replan_lines(find_date_section(content, date))
      verify_replan_lines(replan_lines)
      replan_children_to_move(replan_lines, reject_unskipped: date_i.zero?)
    end

    # Process only original sources: copied replans are left for the next run, even on existing dates.
    source_sections = dates.to_h { |date| [date, find_date_section(content, date)] }
    @destination_counts = Hash.new(0)
    @destination_placements = {}
    @scheduled_arrivals = {}
    @merged_child_counts = Hash.new(0)
    @copied_parents = {}
    @original_content = content
    updated_lines = prepare_updates(source_sections, skips_only)

    dates.each_with_index do |current_date, date_i|
      @source_date_i = date_i
      current_date_section = source_sections.fetch(current_date)

      current_line_edits = {}

      replan_lines = find_replan_lines(current_date_section)
      replan_child_line_is_by_parent = replan_children_to_move(
        replan_lines,
        reject_unskipped: date_i.zero?,
      )
      moved_replan_child_line_is = replan_child_line_is_by_parent.values.flatten

      # Entries are processed in reverse. Repeated top insertions restore their original order; trailing
      # line counts do the same for entries appended to a bracket.
      #
      replan_lines.reverse.each do |replan_line, bracket_i, child_lines, replan_line_i, child_line_is, descendants, source_ancestors|
        next if moved_replan_child_line_is.include?(replan_line_i)

        puts "> Processing replan line: #{replan_line.strip}" if debug

        event_on_current_date = !(@replan_codec.skipped_event?(replan_line) || @replan_codec.once_off_event?(replan_line))

        if event_on_current_date && (skips_only || date_i > 0)
          puts ">> Ignoring" if debug
          next
        end

        updated_replan_line = updated_lines[replan_line]
        planned_line = lstrip_line(updated_replan_line || replan_line)
        replan_data = decode_replan_data(planned_line)
        source_ancestors = source_ancestors.map { |line| updated_lines.fetch(line, line) }

        planned_date = decode_planned_date(replan_data, current_date, replan_line)

        planned_line = handle_time(planned_line, replan_data)
        planned_line = compose_planned_line(planned_line)
        planned_line = apply_interpolations(planned_line, current_date, planned_date, replan_data.skip)
        if replan_data.carry
          carried_child_lines = if replan_child_line_is_by_parent.key?(replan_line_i)
            descendants.map(&:first)
          else
            child_lines
          end
          planned_line = append_children(planned_line, replan_line, carried_child_lines)
        end

        insertion_date = find_preceding_or_existing_date(content, planned_date)

        if insertion_date != planned_date
          content = add_new_date_section(content, insertion_date, planned_date)
        end

        destination_bracket_i = TIME_BLOCK_BRACKETS.fetch(replan_data.time_block, bracket_i)
        content = place_occurrence(
          content, planned_date, destination_bracket_i, planned_line,
          source_ancestors, replan_data,
        )

        edited_replan_line = if replan_data.skip || replan_data.once
          ''
        else
          remove_replan(updated_replan_line || replan_line)
        end

        current_line_edits[replan_line_i] = edited_replan_line
        # Skip/once occurrences leave the source date, so their carried children leave with them.
        if (replan_data.skip || replan_data.once) && replan_data.carry
          carried_child_line_is = if replan_child_line_is_by_parent.key?(replan_line_i)
            descendants.map(&:last)
          else
            child_line_is
          end
          carried_child_line_is.each { |child_line_i| current_line_edits[child_line_i] = '' }
        end

        if skips_only && !debug && replan_line != edited_replan_line
          puts "> Moving line: #{replan_line.strip}"
        end
      end

      # Apply edits to original source lines while retaining any arrivals inserted into this date.
      live_section = find_date_section(content, current_date)
      search_from = 0
      live_lines = live_section.lines
      current_date_section.lines.each_with_index do |line, line_i|
        live_i = (search_from...live_lines.length).find { |i| live_lines[i] == line }
        next unless live_i

        live_lines[live_i] = current_line_edits.fetch(line_i, line)
        search_from = live_i + 1
      end
      content = content.sub(live_section) { live_lines.join }
    end

    content
  end

  private

  # Returns [[replan, bracket_i, child_lines, replan_line_i, child_line_is, descendants,
  # source_ancestors], ...]. Child lines exclude nested replans, since they're normally replanned
  # independently (see #own_children).
  #
  def find_replan_lines(section)
    lines = section.lines
    bracket_i = 0

    lines.each_with_index.filter_map do |line, line_i|
      if line == TIME_BRACKETS_SEPARATOR
        bracket_i += 1
        next
      end

      next unless @replan_codec.replan_line?(line)

      indentation = line[/\A */].length
      descendants = lines.each_with_index.drop(line_i + 1).take_while do |candidate, _|
        !candidate.strip.empty? && candidate[/\A */].length > indentation
      end
      child_lines_with_indices = own_children(descendants)
      source_ancestors = []
      ancestor_indentation = indentation
      lines[1...line_i].reverse_each do |candidate|
        next if candidate == TIME_BRACKETS_SEPARATOR || candidate.strip.empty?
        candidate_indentation = candidate[/\A */].length
        next unless candidate_indentation < ancestor_indentation

        source_ancestors.unshift(candidate)
        ancestor_indentation = candidate_indentation
      end

      [
        line,
        bracket_i,
        child_lines_with_indices.map(&:first),
        line_i,
        child_lines_with_indices.map(&:last),
        descendants,
        source_ancestors,
      ]
    end
  end

  # Update each original occurrence once before copying any parent containers. This also lets a
  # child processed first copy its parent's final text without repeating an interactive update.
  def prepare_updates(source_sections, skips_only)
    updated_lines = {}
    source_sections.each_with_index do |(_, section), date_i|
      replans = find_replan_lines(section)
      moved_children = replan_children_to_move(replans, reject_unskipped: date_i.zero?).values.flatten
      replans.reverse_each do |line, _, children, line_i, _, _, ancestors|
        next if moved_children.include?(line_i)
        data = @replan_codec.extract_replan_tokens(line, allow_placeholder: true)
        next if !data.skip && !data.once && (skips_only || date_i > 0)

        updated = if data.update && !data.skip
          update_line(line.lstrip)
        elsif data.update_full
          full_update_line(line.lstrip)
        end
        next unless updated

        if source_sections.values.join.scan(line).length > 1
          raise "Unsupported: Multiple instances of the same update replan text: #{line.rstrip.inspect}"
        end
        updated_data = decode_replan_data(updated)
        verify_no_children(updated, updated_data, children)
        verify_carry_parent(updated, updated_data, ancestors)
        updated_lines[line] = line[/\A */] + updated.rstrip + "\n"
      end
    end
    updated_lines
  end

  # Parent identities ignore replan metadata. Event identities otherwise retain exact text,
  # including timestamps and comments; copied parents lose their timestamp and comment.
  def event_identity(line)
    remove_replan(line).strip
  end

  def copied_parent_line(line)
    line.lstrip
      .sub(/\A(. )\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?\. /, '\\1')
      .sub(/ #.*$/, '')
      .rstrip
  end

  def child_indices(lines, parent_i = nil)
    indices = []
    i = parent_i ? parent_i + 1 : 0
    end_i = scope_end(lines, parent_i)
    while i < end_i
      if lines[i].strip.empty?
        i += 1
      else
        indices << i
        i = scope_end(lines, i)
      end
    end
    indices
  end

  def find_child(lines, parent_i, identity)
    matches = child_indices(lines, parent_i).select { |i| event_identity(lines[i]) == identity }
    raise "Ambiguous destination match: #{identity.inspect}" if matches.length > 1

    matches.first
  end

  def resolve_parent(lines, path)
    parent_i = nil
    path.each do |identity|
      parent_i = find_child(lines, parent_i, identity)
      return nil unless parent_i
    end
    parent_i
  end

  def block_lines(content, date, bracket_i)
    section = find_date_section(content, date, allow_not_found: true)
    return [] unless section

    section.lines.drop(1).join.split(TIME_BRACKETS_SEPARATOR, -1)[bracket_i].to_s.lines.reject { |line| line.strip.empty? }
  end

  def edit_block(content, date, bracket_i)
    section = find_date_section(content, date)
    header, *body = section.lines
    blocks = body.join.chomp("\n").split(TIME_BRACKETS_SEPARATOR, -1)
    blocks.fill('', blocks.length...TIME_BRACKETS_COUNT + 1)
    lines = blocks[bracket_i].lines
    yield lines
    blocks[bracket_i] = lines.join
    content.sub(section) { header + blocks.join(TIME_BRACKETS_SEPARATOR) + "\n" }
  end

  def scope_end(lines, parent_i)
    return lines.length unless parent_i

    indent = lines[parent_i][/\A */].length
    (parent_i + 1...lines.length).find { |i| !lines[i].strip.empty? && lines[i][/\A */].length <= indent } || lines.length
  end

  # A child extends its newly inserted ancestors too, so later reverse-order insertions stay
  # outside the complete parent group. The source date separates earlier and current insertions.
  def grow_placement(date, bracket_i, path, count)
    while (placement = @destination_placements[[date, bracket_i, path]])
      outer_path, date_i, top = placement
      @destination_counts[[date, bracket_i, outer_path, date_i, top]] += count
      path = outer_path
    end
  end

  def placement_kind(path, text, bracket_i, data)
    data.top && path.empty? && bracket_i.zero? && day_qualifier_line?(text) ? :qualifier : !!data.top
  end

  def insert_in_scope(content, date, bracket_i, path, text, top:)
    line_count = text.lines.count
    content = edit_block(content, date, bracket_i) do |lines|
      parent_i = resolve_parent(lines, path)
      prefix_count = @destination_counts.sum do |(d, b, p, source_i, at_top), count|
        d == date && b == bracket_i && p == path && source_i < @source_date_i && at_top == true ? count : 0
      end
      trailing_count = @destination_counts[[date, bracket_i, path, @source_date_i, false]]
      insertion_i = if top
        base = parent_i ? parent_i + 1 : top_insertion_index(lines)
        # Qualifiers themselves stay before ordinary top entries.
        if !parent_i && bracket_i.zero? && day_qualifier_line?(text)
          base -= @destination_counts[[date, bracket_i, path, @source_date_i, :qualifier]]
        end
        qualifier = !parent_i && bracket_i.zero? && day_qualifier_line?(text)
        base + (qualifier ? 0 : prefix_count)
      else
        scope_end(lines, parent_i) - trailing_count
      end
      indent = parent_i ? lines[parent_i][/\A */].length + 2 : 0
      lines.insert(insertion_i, *text.rstrip.lines.map { |line| "#{' ' * indent}#{line.chomp}\n" })
    end
    kind = top && path.empty? && bracket_i.zero? && day_qualifier_line?(text) ? :qualifier : top
    @destination_counts[[date, bracket_i, path, @source_date_i, kind]] += line_count
    grow_placement(date, bracket_i, path, line_count)
    content
  end

  def place_occurrence(content, date, bracket_i, planned_line, ancestors, data)
    path = ancestors.map { |line| event_identity(line) }
    if data.carry_parent
      parent_line = copied_parent_line(ancestors.last)
      path = path[0...-1]
      lines = block_lines(content, date, bracket_i)
      parent_i = resolve_parent(lines, path)
      path = [] if !path.empty? && !parent_i
      path.each_index do |i|
        ancestor_i = resolve_parent(lines, path.take(i + 1))
        if @replan_codec.replan_line?(lines[ancestor_i])
          raise "Parent-carry destination ancestor has its own replan: #{lines[ancestor_i].strip.inspect}"
        end
      end
      identity = event_identity(parent_line)
      lines = block_lines(content, date, bracket_i)
      parent_i = resolve_parent(lines, path)
      existing_i = find_child(lines, parent_i, identity)
      unless existing_i
        text = parent_line
        content = insert_in_scope(content, date, bracket_i, path, text, top: !!data.top)
        node_path = path + [identity]
        @copied_parents[[date, bracket_i, node_path]] = true
        @destination_placements[[date, bracket_i, node_path]] = [path, @source_date_i, placement_kind(path, parent_line, bracket_i, data)]
      end
      path += [identity]
    elsif !path.empty? && !resolve_parent(block_lines(content, date, bracket_i), path)
      path = []
    end

    identity = event_identity(planned_line.lines.first)
    node_path = path + [identity]
    key = [date, bracket_i, node_path]
    prior = @scheduled_arrivals[key]
    if prior && (prior == :recurring || !data.once)
      raise "Conflicting scheduled occurrences: #{identity.inspect}"
    end
    original_lines = block_lines(@original_content, date, bracket_i)
    original_parent = resolve_parent(original_lines, path)
    original_i = find_child(original_lines, original_parent, identity) if path.empty? || original_parent
    if original_i && @replan_codec.replan_line?(original_lines[original_i])
      raise "Destination already has a replan: #{identity.inspect}"
    end
    @scheduled_arrivals[key] = data.once ? :once : :recurring

    lines = block_lines(content, date, bracket_i)
    parent_i = resolve_parent(lines, path)
    target_i = find_child(lines, parent_i, identity)
    if target_i
      if @replan_codec.replan_line?(lines[target_i]) && !@copied_parents[key] && !prior
        raise "Destination already has a replan: #{identity.inspect}"
      end
      children = planned_line.lines.drop(1)
      content = edit_block(content, date, bracket_i) do |target_lines|
        indent = target_lines[target_i][/\A */]
        target_lines[target_i] = indent + planned_line.lines.first.rstrip + "\n"
        end_i = scope_end(target_lines, target_i) - @merged_child_counts[[key, @source_date_i]]
        target_lines.insert(end_i, *children.map { |line| indent + line })
      end
      grow_placement(date, bracket_i, node_path, children.length)
    else
      content = insert_in_scope(content, date, bracket_i, path, planned_line, top: !!data.top)
      @destination_placements[key] = [path, @source_date_i, placement_kind(path, planned_line, bracket_i, data)]
    end
    @merged_child_counts[[key, @source_date_i]] += planned_line.lines.length - 1
    content
  end

  def verify_replan_lines(replan_lines)
    replan_lines.each do |replan_line, _, child_lines, _, _, _, source_ancestors|
      replan_data = @replan_codec.extract_replan_tokens(replan_line, allow_placeholder: true)
      verify_no_children(replan_line, replan_data, child_lines)
      verify_carry_parent(replan_line, replan_data, source_ancestors)
    end
  end

  def verify_carry_parent(line, replan_data, source_ancestors)
    return unless replan_data.carry_parent

    if source_ancestors.empty?
      raise "Parent-carry entry requires a parent: #{line.strip.inspect}"
    elsif source_ancestors[0...-1].any? { |ancestor| @replan_codec.replan_line?(ancestor) }
      raise "Parent-carry entry has an ancestor above its parent with its own replan: #{line.strip.inspect}"
    end
  end

  def verify_no_children(replan_line, replan_data, child_lines)
    # child_lines excludes nested replans, which are scheduled independently.
    return unless child_lines.any? && (replan_data.skip || replan_data.once) && !replan_data.carry

    raise "Skip/once replan entry has children: #{replan_line.rstrip.inspect}"
  end

  def replan_children_to_move(replan_lines, reject_unskipped:)
    replan_lines_by_line_i = replan_lines.to_h { |replan_line| [replan_line.fetch(3), replan_line] }

    replan_lines.each_with_object({}) do |replan_line, result|
      line, _, _, line_i, _, descendants = replan_line
      replan_data = @replan_codec.extract_replan_tokens(line, allow_placeholder: true)
      next unless replan_data.carry

      replan_children = descendants.filter_map do |_, descendant_line_i|
        replan_lines_by_line_i[descendant_line_i]
      end
      next if replan_children.empty?

      if !replan_data.skip
        if reject_unskipped
          raise "Carry replan entry has replan children without `s`: #{line.strip.inspect}"
        end

        next
      end

      replan_children.each do |replan_child|
        child_line, _, _, _, _, child_descendants = replan_child
        if child_descendants.any?
          raise "Replan child has children: #{child_line.strip.inspect}"
        end
      end

      result[line_i] = replan_children.map { |replan_child| replan_child.fetch(3) }
    end
  end

  # Nested replan lines are normally events of their own, so they don't move with the parent.
  #
  def own_children(descendants)
    nested_replan_indentation = nil

    descendants.select do |line, _|
      indentation = line[/\A */].length

      if nested_replan_indentation && indentation <= nested_replan_indentation
        nested_replan_indentation = nil
      end

      if nested_replan_indentation
        false
      elsif @replan_codec.replan_line?(line)
        nested_replan_indentation = indentation
        false
      else
        true
      end
    end
  end

  def append_children(planned_line, replan_line, child_lines)
    return planned_line if child_lines.empty?

    parent_indentation = replan_line[/\A */]
    dedented_children = child_lines.map { |line| line.sub(/\A#{Regexp.escape(parent_indentation)}/, '') }
    "#{planned_line.rstrip}\n#{dedented_children.join}"
  end

  def lstrip_line(line)
    line.lstrip
  end

  def decode_replan_data(line)
    replan_data = @replan_codec.extract_replan_tokens(line)

    if replan_data.interval.nil? && replan_data.skip.nil? && replan_data.next.nil?
      raise "No period found (required by the options): #{line}"
    end

    replan_data
  end

  def update_line(line)
    @replan_codec.update_line(line)
  end

  def full_update_line(line)
    @replan_codec.full_update_line(line)
  end

  def decode_planned_date(replan_data, current_date, line)
    replan_value = replan_data.next || replan_data.interval

    # WATCH OUT!!! Don't use `Date.today` - use `current_date`, since when replanning, `Date.today` is
    # actually past.
    #
    displacement = case replan_value
      when /^\d+$/
        replan_value.to_i
      when /^\d+w$/
        7 * replan_value[0..-2].to_i
      when /^\d+(\.\d)?m$/
        30 * replan_value[0..-2].to_f
      when /^\d+(\.\d)?y$/
        365 * replan_value[0..-2].to_f
      when /^\+(\d)?(\w{3})$/
        weekday_int = Date.strptime($LAST_MATCH_INFO[2], '%a').wday
        weekday_factor = $LAST_MATCH_INFO[1]&.to_i || 1

        first_day_next_month = Date.new(current_date.year, current_date.month, 1) >> 1
        offset = (weekday_int - first_day_next_month.wday) % 7
        replanned_date = first_day_next_month + offset + (weekday_factor - 1) * 7

        replanned_date - current_date
      when /^-(\d+)$/
        first_day_next_month = Date.new(
          current_date.next_month.year,
          current_date.next_month.month,
          1
        )

        current_candidate = first_day_next_month - $LAST_MATCH_INFO[1].to_i

        if current_candidate > current_date
          current_candidate - current_date
        else
          first_day_next_month.next_month - $LAST_MATCH_INFO[1].to_i - current_date
        end
      when /^-(\d+)?(\w{3})$/
        weekday_int = Date.strptime($LAST_MATCH_INFO[2], '%a').wday
        weekday_factor = $LAST_MATCH_INFO[1]&.to_i || 1

        # Same algorithm as "First day of month" version, only difference being that it refers to the
        # last day of the current month instead of the first day of the next month.

        last_day_current_month = Date.new(current_date.year, current_date.month + 1, 1) - 1
        offset = (weekday_int - last_day_current_month.wday) % 7
        replanned_date = last_day_current_month + offset + (weekday_factor - 1) * 7

        replanned_date - current_date
      when /^(\w{3})(\+)?$/
        # strptime() finds the closest next weekday, starting from (can be chosen) `Date.today`.
        #---
        # In this case, Timecop correctly handles Date.parse (see ReplanHelper#convert_header_to_date),
        # however, considering the project quality, it's safer to avoid it.
        #
        next_weekday_occurrence = Date.strptime($LAST_MATCH_INFO[1], '%a')

        # Difference in days, between current_date  and the weekday corresponding to `next_weekday_occurrence`;
        # covers both cases where `next_weekday_occurrence`` is greater or less than `current_date``
        #
        displacement = (next_weekday_occurrence - current_date) % 7

        # If they were same, we need to correct, though.
        #
        displacement += 7 if displacement == 0

        displacement += 7 if $LAST_MATCH_INFO[2]

        displacement
      when %r|^\w{3}/\d{1,2}$|, %r|^\d{1,2}/\w{3}$|
        # The current year is always assigned.
        #
        format = replan_value.match?(/^\d/) ? "%d/%b" : "%b/%d"
        next_date = Date.strptime(replan_value, format)

        next_date >>= 12 if next_date < current_date

        next_date - current_date
      else
        raise "Invalid replan value: #{replan_value.inspect}; line: #{line.inspect}"
      end

    current_date + displacement
  end

  def remove_replan(line)
    @replan_codec.remove_replan(line)
  end

  def apply_interpolations(line, current_date, planned_date, skip)
    INTERPOLATIONS.each do |matcher, replacement|
      if line =~ /\{\{#{matcher}\}\}/
        new_content = replacement[Regexp.last_match, current_date, planned_date, skip]
        if new_content
          new_line = line.gsub(/\{\{#{matcher}\}\}/, "\{\{#{new_content}\}\}")
          puts "> Interpolation: #{current_date.strftime("%b/%d")}:'#{line[/^ *\S (.+) \(replan/, 1]}' → #{planned_date.strftime("%b/%d")}:'#{new_line[/^ *\S (.+) \(replan/, 1]}'"
          line = new_line
        end
      end
    end

    line
  end

  def handle_time(line, replan_data)
    if replan_data.once
      line
    elsif replan_data.fixed
      if replan_data.fixed_time
        # Replace the time with the specified one.
        #
        line.sub(/(?<=^. )(\d{1,2}:\d{2}(-\d{1,2}:\d{2})?\. )?/, "#{replan_data.fixed_time}. ")
      elsif line.start_with?(/. \d{1,2}:\d{2}\b/)
        line
      else
        raise "Fixed timestamp is set, but no timestamp is provided: #{line.rstrip.inspect}"
      end
    else
      # Remove the time.
      #
      line.sub(/(?<=^. )\d{1,2}:\d{2}. /, '')
    end
  end

  def compose_planned_line(line)
    @replan_codec.rewrite_replan(line)
  end
end
