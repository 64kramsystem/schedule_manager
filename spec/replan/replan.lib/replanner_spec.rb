require 'rspec'
require 'timecop'

require_relative '../../../replan.lib/replanner.rb'

module ReplannerSpecHelper
  CURRENT_DATE = Date.new(2021, 9, 20)

  # A simpler (UX-wise, not code-wise) implementation is to automatically gather the current_date
  # from the first header in the test_content, although this may be a bit too magical.
  #
  def assert_replan(test_content, expected_next_date_section, current_date: CURRENT_DATE, skips_only: false, expected_stdout: //, exact: false)
    # As of Jul/2024, an empty ending line is required by the parser, but it's very easy to forget,
    # and it causes a confusing error. For this reason, we add it automatically (if needed).
    #
    test_content += "\n" if !test_content.end_with?("\n\n")

    Timecop.freeze(current_date) do
      expect {
        result = subject.execute(test_content, skips_only:)
        matcher = exact ? eq(expected_next_date_section) : include(expected_next_date_section)
        expect(result).to matcher
      }.to output(expected_stdout).to_stdout
    end
  end
end

describe Replanner do
  include ReplannerSpecHelper

  context "Events" do
    it "moves replan children with a skipped c parent" do
      test_content = <<~TXT
          MON 20/SEP/2021
      * gym chest (replan cs 3)
        + unload dishwasher
        + stretch
        + C:/14 (replan s 1)
        + review (replan o in 2)

          THU 23/SEP/2021
      - existing

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021

          THU 23/SEP/2021
      - existing
      * gym chest (replan c 3)
        + unload dishwasher
        + stretch
        + C:/14 (replan s 1)
        + review (replan o in 2)
      -----
      -----
      -----
      -----

      TXT

      assert_replan(test_content, expected_updated_content, exact: true)
    end

    it "rejects replan children on a c parent without s" do
      test_content = <<~TXT
          MON 20/SEP/2021
      * gym chest (replan c 3)
        + C:/14 (replan 1)

      TXT

      expect {
        subject.execute(test_content)
      }.to raise_error('Carry replan entry has replan children without `s`: "* gym chest (replan c 3)"')
    end

    it "rejects a replan child with children" do
      test_content = <<~TXT
          MON 20/SEP/2021
      * gym chest (replan cs 3)
        + C:/14 (replan 1)
          - nested child

      TXT

      expect {
        subject.execute(test_content)
      }.to raise_error('Replan child has children: "+ C:/14 (replan 1)"')
    end

    it "rejects children on a once-off event" do
      test_content = <<~TXT
          MON 20/SEP/2021
      + BOM (replan oA thu)
        + check current account

      TXT

      expect {
        subject.execute(test_content)
      }.to raise_error('Skip/once replan entry has children: "+ BOM (replan oA thu)"')
    end

    it "replans a nested replan independently of a skipped parent" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - skipped parent (replan s 7)
        - nested child (replan 1)

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
        - nested child

          TUE 21/SEP/2021
      - nested child (replan 1)
      -----
      -----
      -----
      -----

          MON 27/SEP/2021
      - skipped parent (replan 7)
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "rejects a plain child alongside an independent nested replan" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - skipped parent (replan s 7)
        - nested child (replan 1)
        - plain child

      TXT

      expect {
        subject.execute(test_content)
      }.to raise_error('Skip/once replan entry has children: "- skipped parent (replan s 7)"')
    end

    it "rejects children when a full update adds the skip flag" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - parent (replan U 7)
        - child

      TXT

      expect_any_instance_of(InputHelper)
        .to receive(:ask)
        .with("Enter the new description:", prefill: "parent (replan U 7)")
        .and_return("parent (replan s 7)")

      expect {
        subject.execute(test_content)
      }.to raise_error('Skip/once replan entry has children: "- parent (replan s 7)"')
    end

    it "rejects invalid children before prompting for updates on earlier dates" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - editable (replan u 7)

          TUE 21/SEP/2021
      - invalid skipped parent (replan s 7)
        - child

      TXT

      expect_any_instance_of(InputHelper).not_to receive(:ask)

      expect {
        subject.execute(test_content)
      }.to raise_error('Skip/once replan entry has children: "- invalid skipped parent (replan s 7)"')
    end

    it "copies all descendants when advancing a recurring event with c" do
      test_content = <<~TXT
          MON 20/SEP/2021
      + recurring parent (replan c 7)
        - child
          - grandchild
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      + recurring parent
        - child
          - grandchild

          MON 27/SEP/2021
      + recurring parent (replan c 7)
        - child
          - grandchild
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "moves children when skipping a recurring event with c" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - … call m/p {{-4}} (replan csN 1w in 1)
        - REGALO PAPA

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021

          TUE 21/SEP/2021
      -----
      - … call m/p {{-5}} (replan cN 1w)
        - REGALO PAPA
      -----
      -----
      -----

      TXT

      expected_stdout = <<~TXT
        > Interpolation: Sep/20:'… call m/p {{-4}}' → Sep/21:'… call m/p {{-5}}'
      TXT

      assert_replan(test_content, expected_updated_content, expected_stdout:, exact: true)
    end

    it "moves children when scheduling an event once with c" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - down movies (replan oNc tue)
        - together (2025)
        - obex

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021

          TUE 21/SEP/2021
      -----
      - down movies
        - together (2025)
        - obex
      -----
      -----
      -----

      TXT

      assert_replan(test_content, expected_updated_content, exact: true)
    end

    it "leaves descendants on the current occurrence when c is absent" do
      test_content = <<~TXT
          MON 20/SEP/2021
      + recurring parent (replan 7)
        - child
          - grandchild
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      + recurring parent
        - child
          - grandchild

          MON 27/SEP/2021
      + recurring parent (replan 7)
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "moves a level-2 event under the matching root in the destination block" do
      test_content = <<~TXT
          MON 20/SEP/2021
      * movies
        - download (replan A 2)
        - watch (replan A 2)

          WED 22/SEP/2021
      * movies
        - morning
      -----
      -----
      * movies
        - afternoon
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      * movies
        - download
        - watch

          WED 22/SEP/2021
      * movies
        - morning
      -----
      -----
      * movies
        - afternoon
        - download (replan A 2)
        - watch (replan A 2)
      -----
      -----

      TXT

      assert_replan(test_content, expected_updated_content, exact: true)
    end

    it "keeps root and bracket top ordering when moving a level-2 top event" do
      test_content = <<~TXT
          MON 20/SEP/2021
      * movies
        - nested top (replan ^A 2)
      - first top (replan ^A 2)
      - second top (replan ^A 2)

          WED 22/SEP/2021
      -----
      -----
      * movies
        - existing child
      - existing event
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      * movies
        - nested top
      - first top
      - second top

          WED 22/SEP/2021
      -----
      -----
      - first top (replan ^A 2)
      - second top (replan ^A 2)
      * movies
        - nested top (replan ^A 2)
        - existing child
      - existing event
      -----
      -----

      TXT

      assert_replan(test_content, expected_updated_content, exact: true)
    end

    it "uses ordinary block placement when the root exists only in another destination block" do
      test_content = <<~TXT
          MON 20/SEP/2021
      * movies
        - download (replan A 2)

          WED 22/SEP/2021
      * movies
        - morning
      -----
      -----
      - afternoon
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      * movies
        - download

          WED 22/SEP/2021
      * movies
        - morning
      -----
      -----
      - afternoon
      - download (replan A 2)
      -----
      -----

      TXT

      assert_replan(test_content, expected_updated_content, exact: true)
    end

    context 'carrying root parents with p' do
      ['9:30', '12:30-13:00'].each do |time|
        ['p', 'sp', 'op'].each do |flags|
          it "copies the parent without its #{time} time for #{flags}" do
            period = flags.include?('o') ? 'in 2' : '2'
            test_content = <<~TXT
                MON 20/SEP/2021
            * #{time}. movies
              - download (replan #{flags} #{period})

            TXT

            source_child = flags == 'p' ? "  - download\n" : ''
            destination_replan = flags == 'op' ? '' : ' (replan p 2)'
            expected_updated_content = <<~TXT
                MON 20/SEP/2021
            * #{time}. movies
            #{source_child}
                WED 22/SEP/2021
            * movies
              - download#{destination_replan}
            -----
            -----
            -----
            -----

            TXT

            assert_replan(test_content, expected_updated_content, exact: true)
          end
        end
      end

      it 'reuses an untimed destination parent for children from timed parents' do
        test_content = <<~TXT
            MON 20/SEP/2021
        * 9:30. movies
          - download (replan sp 2)
        * 12:30-13:00. movies
          - watch (replan sp 2)

            WED 22/SEP/2021
        * movies
          - existing

        TXT

        expected_updated_content = <<~TXT
            MON 20/SEP/2021
        * 9:30. movies
        * 12:30-13:00. movies

            WED 22/SEP/2021
        * movies
          - existing
          - download (replan p 2)
          - watch (replan p 2)
        -----
        -----
        -----
        -----

        TXT

        assert_replan(test_content, expected_updated_content, exact: true)
      end

      {
        'p' => ["  - download\n", ' (replan p 2)'],
        'sp' => ['', ' (replan p 2)'],
        'op' => ['', ''],
      }.each do |flags, (source_child, destination_replan)|
        it "copies only the root parent for #{flags}" do
          period = flags.include?('o') ? 'in 2' : '2'
          test_content = <<~TXT
              MON 20/SEP/2021
          * movies
            - download (replan #{flags} #{period})
            - sibling

          TXT

          expected_updated_content = <<~TXT
              MON 20/SEP/2021
          * movies
          #{source_child}  - sibling

              WED 22/SEP/2021
          * movies
            - download#{destination_replan}
          -----
          -----
          -----
          -----

          TXT

          assert_replan(test_content, expected_updated_content, exact: true)
        end
      end

      it 'reuses the parent in the requested block and carries the child subtree with c' do
        test_content = <<~TXT
            MON 20/SEP/2021
        * movies
          - download (replan cspA 2)
            - select quality
              - prefer HD

            WED 22/SEP/2021
        * movies
          - morning
        -----
        -----
        * movies
          - existing
        -----
        -----

        TXT

        expected_updated_content = <<~TXT
            MON 20/SEP/2021
        * movies

            WED 22/SEP/2021
        * movies
          - morning
        -----
        -----
        * movies
          - existing
          - download (replan cpA 2)
            - select quality
              - prefer HD
        -----
        -----

        TXT

        assert_replan(test_content, expected_updated_content, exact: true)
      end

      ['', '^'].each do |top|
        it "keeps newly copied parents and their children together with #{top.empty? ? 'ordinary' : 'top'} placement" do
          test_content = <<~TXT
              MON 20/SEP/2021
          - first (replan #{top}A 2)
          * movies
            - download (replan p#{top}A 2)
            - watch (replan p#{top}A 2)
          - last (replan #{top}A 2)

              WED 22/SEP/2021
          * movies
            - morning
          -----
          -----
          - existing
          -----
          -----

          TXT

          expected_updated_content = <<~TXT
              MON 20/SEP/2021
          - first
          * movies
            - download
            - watch
          - last

              WED 22/SEP/2021
          * movies
            - morning
          -----
          -----
          #{top.empty? ? "- existing\n" : ''}- first (replan #{top}A 2)
          * movies
            - download (replan p#{top}A 2)
            - watch (replan p#{top}A 2)
          - last (replan #{top}A 2)
          #{top.empty? ? '' : "- existing\n"}-----
          -----

          TXT

          assert_replan(test_content, expected_updated_content, exact: true)
        end
      end

      it 'keeps top ordering across source dates when a copied parent gains more children' do
        test_content = <<~TXT
            MON 20/SEP/2021
        * movies
          - monday (replan p^ 3)
        - monday standalone (replan ^ 3)

            TUE 21/SEP/2021
        - tuesday first (replan s^ 2)
        * movies
          - tuesday (replan sp^ 2)
        - tuesday standalone (replan s^ 2)

            THU 23/SEP/2021
        - existing

        TXT

        expected_updated_content = <<~TXT
            MON 20/SEP/2021
        * movies
          - monday
        - monday standalone

            TUE 21/SEP/2021
        * movies

            THU 23/SEP/2021
        * movies
          - monday (replan p^ 3)
          - tuesday (replan p^ 2)
        - monday standalone (replan ^ 3)
        - tuesday first (replan ^ 2)
        - tuesday standalone (replan ^ 2)
        - existing
        -----
        -----
        -----
        -----

        TXT

        assert_replan(test_content, expected_updated_content, exact: true)
      end

      it 'keeps an appended parent group together when a later source date adds a child' do
        test_content = <<~TXT
            MON 20/SEP/2021
        * movies
          - monday (replan p 3)

            TUE 21/SEP/2021
        - tuesday first (replan s 2)
        * movies
          - tuesday (replan sp 2)

            THU 23/SEP/2021
        - existing

        TXT

        expected_updated_content = <<~TXT
            MON 20/SEP/2021
        * movies
          - monday

            TUE 21/SEP/2021
        * movies

            THU 23/SEP/2021
        - existing
        * movies
          - monday (replan p 3)
          - tuesday (replan p 2)
        - tuesday first (replan 2)
        -----
        -----
        -----
        -----

        TXT

        assert_replan(test_content, expected_updated_content, exact: true)
      end

      it 'keeps copied day qualifiers and their child groups ahead of ordinary top entries' do
        test_content = <<~TXT
            MON 20/SEP/2021
        S first qualifier
          - first (replan p^ 2)
        % second qualifier
          - second (replan p^ 2)
          - third (replan p^ 2)
        - standalone (replan ^ 2)

            WED 22/SEP/2021
        S existing qualifier
          - existing child
        - existing

        TXT

        expected_updated_content = <<~TXT
            MON 20/SEP/2021
        S first qualifier
          - first
        % second qualifier
          - second
          - third
        - standalone

            WED 22/SEP/2021
        S existing qualifier
          - existing child
        S first qualifier
          - first (replan p^ 2)
        % second qualifier
          - second (replan p^ 2)
          - third (replan p^ 2)
        - standalone (replan ^ 2)
        - existing
        -----
        -----
        -----
        -----

        TXT

        assert_replan(test_content, expected_updated_content, exact: true)
      end

      {
        'an entry without a parent' => "- child (replan p 2)\n",
        'a child of a nested parent' => "* root\n  - parent\n    - child (replan p 2)\n",
      }.each do |description, entries|
        it "rejects #{description}" do
          content = "    MON 20/SEP/2021\n#{entries}\n"
          expect { subject.execute(content) }.to raise_error(/Parent-carry entry requires a direct root parent/)
        end
      end

      it 'rejects a parent with its own replan before prompting for updates' do
        test_content = <<~TXT
            MON 20/SEP/2021
        * movies (replan U 7)
          - download (replan p 2)

        TXT

        expect_any_instance_of(InputHelper).not_to receive(:ask)
        expect { subject.execute(test_content) }.to raise_error(/Parent-carry entry has a parent with its own replan/)
      end

      it 'validates p introduced by a full update' do
        test_content = <<~TXT
            MON 20/SEP/2021
        - download (replan U 2)

        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with('Enter the new description:', prefill: 'download (replan U 2)')
          .and_return('download (replan Up 2)')

        expect { subject.execute(test_content) }.to raise_error(/Parent-carry entry requires a direct root parent/)
      end
    end

    it "should be moved according to their current day property, in default mode" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - today current (replan 7)
      - today skip (replan s 7)
      - today once (replan o in 7)

          TUE 21/SEP/2021
      - tomorrow current (replan 7)
      - tomorrow skip (replan s 7)
      - tomorrow once (replan o in 7)
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      - today current

          TUE 21/SEP/2021
      - tomorrow current (replan 7)

          MON 27/SEP/2021
      - today current (replan 7)
      - today skip (replan 7)
      - today once
      -----
      -----
      -----
      -----

          TUE 28/SEP/2021
      - tomorrow skip (replan 7)
      - tomorrow once
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "should be moved according to their current day property, in skips-only mode" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - today current (replan 7)
      - today skip (replan s 7)
      - today once (replan o in 7)

          TUE 21/SEP/2021
      - tomorrow current (replan 7)
      - tomorrow skip (replan s 7)
      - tomorrow once (replan o in 7)
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      - today current (replan 7)

          TUE 21/SEP/2021
      - tomorrow current (replan 7)

          MON 27/SEP/2021
      - today skip (replan 7)
      - today once
      -----
      -----
      -----
      -----

          TUE 28/SEP/2021
      - tomorrow skip (replan 7)
      - tomorrow once
      -----
      -----
      -----
      -----
      TXT

      expected_stdout = <<~TXT
        > Moving line: - today once (replan o in 7)
        > Moving line: - today skip (replan s 7)
        > Moving line: - tomorrow once (replan o in 7)
        > Moving line: - tomorrow skip (replan s 7)
      TXT

      assert_replan(test_content, expected_updated_content, skips_only: true, expected_stdout:)
    end

    it 'should process skipped/once-off events on future days' do
      test_content = <<~TXT
          MON 20/SEP/2021

          TUE 21/SEP/2021
      - tomorrow skip (replan s 7)
      - tomorrow once (replan o in 7)
      TXT

      expected_next_date_section = <<~TXT
          TUE 28/SEP/2021
      - tomorrow skip (replan 7)
      - tomorrow once
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_next_date_section)
    end
  end

  it "Should replan a 10+ 'm' date" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo (replan 10m)

    TXT

    expected_updated_content = <<~TXT
        SUN 17/JUL/2022
    - foo (replan 10m)
    TXT

    assert_replan(test_content, expected_updated_content)
  end

  it "Should raise an error if there are multiple instances of the same update replan text" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo (replan u 1)
    - foo (replan u 1)

    TXT

      expect_any_instance_of(InputHelper)
        .to receive(:ask)
        .with("Enter the new description:", prefill: "foo")
        .and_return("foo")

    error_message = 'Unsupported: Multiple instances of the same update replan text: "- foo (replan u 1)"'
    expect { subject.execute(test_content) }.to raise_error(RuntimeError, error_message)
  end

  context "Month-relative" do
    context "without number specifier" do
      # The idea behind logic is that if a monthly event happened during a given month, and its reference
      # is changed, the next occurence is necessarily on the next month.
      # If an event is both shifted (eg. to the following week), and its reference changed, one can use
      # the skip+on_day functionality.
      #
      it "Should replan on the the next month, even when available during the current" do
        test_content = <<~TXT
            WED 01/SEP/2021
        - foo (replan +thu)
        TXT

        expected_next_date_section = <<~TXT
            WED 01/SEP/2021
        - foo

            THU 07/OCT/2021
        - foo (replan +thu)
        TXT

        assert_replan(test_content, expected_next_date_section, current_date: Date.new(2021, 9, 1))
      end

      it "Should replan on the same month when not available" do
        test_content = <<~TXT
            MON 27/SEP/2021
        - foo (replan +mon)
        TXT

        expected_next_date_section = <<~TXT
            MON 27/SEP/2021
        - foo

            MON 04/OCT/2021
        - foo (replan +mon)
        TXT

        assert_replan(test_content, expected_next_date_section, current_date: Date.new(2021, 9, 27))
      end

      it "Should replan a last weekday of month interval" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan -thu)
        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - foo

            THU 30/SEP/2021
        - foo (replan -thu)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end
    end # context "without number specifier" do

    context "with number specifier" do
      it "Should replan on the the next month, even when available during the current" do
        test_content = <<~TXT
            TUE 11/JUN/2024
        - foo (replan +2tue)
        TXT

        expected_next_date_section = <<~TXT
            TUE 11/JUN/2024
        - foo

            TUE 09/JUL/2024
        - foo (replan +2tue)
        TXT

        assert_replan(test_content, expected_next_date_section, current_date: Date.new(2024, 6, 11))
      end
    end # context "with number specifier" do
  end # context "last numbered day of month interval"

  context "last numbered day of month interval" do
    # This behavior may be changed.
    #
    it "Should replan on the same month when available" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan -1)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - foo

          THU 30/SEP/2021
      - foo (replan -1)
      TXT

      assert_replan(test_content, expected_next_date_section)
    end

    it "Should replan on the next month when not available" do
      test_content = <<~TXT
          THU 30/SEP/2021
      - foo (replan -1)
      TXT

      expected_next_date_section = <<~TXT
          THU 30/SEP/2021
      - foo

          SUN 31/OCT/2021
      - foo (replan -1)
      TXT

      assert_replan(test_content, expected_next_date_section, current_date: Date.new(2021, 9, 30))
    end
  end # context "last numbered day of month interval"

  it "Should add the replanned lines to the same time bracket as the original" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo1 (replan 7)
    -----
    - foo1 (replan 7)
    - foo2 (replan 7)
    -----
    - foo3 (replan 7)
    -----
    - foo4 (replan 7)
    -----

        MON 27/SEP/2021
    - bar1
    -----
    - bar2
    -----
    -----
    - bar4
    -----

    TXT

    expected_updated_content = <<~TXT
        MON 27/SEP/2021
    - bar1
    - foo1 (replan 7)
    -----
    - bar2
    - foo1 (replan 7)
    - foo2 (replan 7)
    -----
    - foo3 (replan 7)
    -----
    - bar4
    - foo4 (replan 7)
    -----
    TXT

    assert_replan(test_content, expected_updated_content)
  end

  it "Should add missing brackets, when adding replan lines" do
    test_content = <<~TXT
        MON 20/SEP/2021
    - foo1 (replan 7)
    -----
    - foo1 (replan 7)
    -----
    -----
    -----

        MON 27/SEP/2021
    - foo

    TXT

    expected_updated_content = <<~TXT
        MON 27/SEP/2021
    - foo
    - foo1 (replan 7)
    -----
    - foo1 (replan 7)
    -----
    -----
    -----
    TXT

    assert_replan(test_content, expected_updated_content)
  end

  context "Time-block flags" do
    it "places M, N, A, and E replans at the end of their requested blocks" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. morning (replan oM thu)
      - noon (replan oN thu)
      - afternoon (replan oA thu)
      - evening (replan oE thu)

          THU 23/SEP/2021
      - existing morning
      -----
      - existing noon
      -----
      - existing afternoon
      -----
      - existing evening
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      - existing morning
      - 12:30. morning
      -----
      - existing noon
      - noon
      -----
      - existing afternoon
      - afternoon
      -----
      - existing evening
      - evening
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "retains the flag after placing a recurring replan" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - recurring (replan A thu)

          THU 23/SEP/2021
      -----
      -----
      - existing afternoon
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      -----
      -----
      - existing afternoon
      - recurring (replan A thu)
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "preserves multiline event order when placing replans at the end of one block" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - first (replan cA thu)
        - first child
      - second (replan cA thu)
        - second child

          THU 23/SEP/2021
      -----
      -----
      - existing afternoon
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      -----
      -----
      - existing afternoon
      - first (replan cA thu)
        - first child
      - second (replan cA thu)
        - second child
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "preserves order when replans from multiple dates target the same block" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - from monday (replan oA thu)

          TUE 21/SEP/2021
      - from tuesday (replan oA thu)

          THU 23/SEP/2021
      -----
      -----
      - existing afternoon
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      -----
      -----
      - existing afternoon
      - from monday
      - from tuesday
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end
  end

  context "Top flag" do
    it "places caret replans before existing entries and retains the flag" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - first (replan ^ 7)
      - second (replan ^ 7)

          MON 27/SEP/2021
      - existing
      -----
      -----
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          MON 27/SEP/2021
      - first (replan ^ 7)
      - second (replan ^ 7)
      - existing
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    ['S', '%'].each do |day_event_qualifier|
      it "places caret replans after #{day_event_qualifier} day qualifiers" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - top (replan ^ 7)

            MON 27/SEP/2021
        #{day_event_qualifier} day event
          - nested detail
        - existing
        -----
        -----
        -----
        -----

        TXT

        expected_updated_content = <<~TXT
            MON 27/SEP/2021
        #{day_event_qualifier} day event
          - nested detail
        - top (replan ^ 7)
        - existing
        -----
        -----
        -----
        -----
        TXT

        assert_replan(test_content, expected_updated_content)
      end
    end

    it "preserves the order of multiple caret day qualifiers from one source date" do
      test_content = <<~TXT
          MON 20/SEP/2021
      S first qualifier (replan o^ thu)
      % second qualifier (replan o^ thu)

          THU 23/SEP/2021
      - existing
      -----
      -----
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      S first qualifier
      % second qualifier
      - existing
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "preserves multiline caret day qualifier order from one source date" do
      test_content = <<~TXT
          MON 20/SEP/2021
      S first qualifier (replan c^ 3)
        - first child
      % second qualifier (replan c^ 3)
        - second child

          THU 23/SEP/2021
      - existing
      -----
      -----
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      S first qualifier (replan c^ 3)
        - first child
      % second qualifier (replan c^ 3)
        - second child
      - existing
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "retains caret when replanning fixed skipped entries" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - fixed skip (replan f10:00s^ 7)

          MON 27/SEP/2021
      - existing
      -----
      -----
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          MON 27/SEP/2021
      - 10:00. fixed skip (replan f10:00^ 7)
      - existing
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "combines with a retained time-block flag" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - recurring (replan A^ 7)

          MON 27/SEP/2021
      -----
      -----
      - existing afternoon
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          MON 27/SEP/2021
      -----
      -----
      - recurring (replan ^A 7)
      - existing afternoon
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "preserves source-date order for caret replans targeting one block" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - from monday (replan o^ thu)

          TUE 21/SEP/2021
      - from tuesday (replan o^ thu)

          THU 23/SEP/2021
      - existing
      -----
      -----
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      - from monday
      - from tuesday
      - existing
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "orders multiline caret entries and replanned day qualifiers across source dates" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - from monday (replan c^ thu)
        - monday child

          TUE 21/SEP/2021
      S tuesday qualifier (replan o^ thu)

          WED 22/SEP/2021
      - from wednesday (replan o^ thu)

          THU 23/SEP/2021
      - existing
      -----
      -----
      -----
      -----

      TXT

      expected_updated_content = <<~TXT
          THU 23/SEP/2021
      S tuesday qualifier
      - from monday (replan c^ thu)
        - monday child
      - from wednesday
      - existing
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_updated_content)
    end
  end

  context "Interpolations" do
    it "Should apply the date interpolation {{%a/%d}}" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo {{sun/19}} (replan 2)
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      - foo {{sun/19}}

          WED 22/SEP/2021
      - foo {{mon/20}} (replan 2)
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "Should not apply the date interpolation {{date}} on :skip" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo {{sun/19}} (replan s 2)
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - foo {{sun/19}} (replan 2)
      TXT

      assert_replan(test_content, expected_updated_content)
    end

    it "Should apply the days past interpolation {{-N}}, with reset" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo {{-3}} (replan 1w)
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021
      - foo {{-3}}

          MON 27/SEP/2021
      - foo {{-7}} (replan 1w)
      TXT

      expected_stdout = <<~TXT
        > Interpolation: Sep/20:'foo {{-3}}' → Sep/27:'foo {{-7}}'
      TXT

      assert_replan(test_content, expected_updated_content, expected_stdout:)
    end

    it "Should apply the days past interpolation {{-N}} on :skip, with accumulation" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - bar {{-3}} (replan s 1w)
      TXT

      expected_updated_content = <<~TXT
          MON 20/SEP/2021

          MON 27/SEP/2021
      - bar {{-10}} (replan 1w)
      TXT

      expected_stdout = <<~TXT
        > Interpolation: Sep/20:'bar {{-3}}' → Sep/27:'bar {{-10}}'
      TXT

      assert_replan(test_content, expected_updated_content, expected_stdout:)
    end
  end # context "Interpolations"

  context "skip" do
    it "Should skip a replan" do
      # The second replan triggered a bug causing duplication of the line.
      #
      test_content = <<~TXT
          MON 27/SEP/2021
      - foo (replan s 2)
      - bar (replan s mon)
      TXT

      expected_next_date_section = <<~TXT
          MON 27/SEP/2021

          WED 29/SEP/2021
      - foo (replan 2)
      -----
      -----
      -----
      -----

          MON 04/OCT/2021
      - bar (replan mon)
      -----
      -----
      -----
      -----
      TXT

      assert_replan(test_content, expected_next_date_section)
    end

    it "Should skip an update, without updating the line" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan su 2)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - foo (replan u 2)
      TXT

      expect_any_instance_of(InputHelper)
        .not_to receive(:ask)

      assert_replan(test_content, expected_next_date_section)
    end

    # The reason is that the user may want to change the day.
    #
    it "Should prompt for changes when skipping an update full" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan sU thu)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - foo (replan U wed)
      TXT

      expect_any_instance_of(InputHelper)
        .to receive(:ask)
        .with("Enter the new description:", prefill: "foo (replan sU thu)")
        .and_return("foo (replan sU wed)")

      assert_replan(test_content, expected_next_date_section)
    end
  end # context "skip"

  context "once scheduling" do
    it "Should schedule a task once in the future, with number of days" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo (replan o in 2)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - 12:30. foo
      TXT

      assert_replan(test_content, expected_next_date_section)
    end

    it "Should schedule a task once in the future, with a weekday" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo (replan o wed)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 22/SEP/2021
      - 12:30. foo
      TXT

      assert_replan(test_content, expected_next_date_section)
    end

    it "Should schedule a task once in the future, with a plus weekday" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo (replan o wed+)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          WED 29/SEP/2021
      - 12:30. foo
      TXT

      assert_replan(test_content, expected_next_date_section)
    end


    it "Should schedule a task once in the future, with number of weeks" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo (replan o in 1w)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021

          MON 27/SEP/2021
      - 12:30. foo
      TXT

      assert_replan(test_content, expected_next_date_section)
    end
  end

  context "timestamp handling" do
    it "Should remove the timestamp, if there isn't a fixed one" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo (replan 2)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - 12:30. foo

          WED 22/SEP/2021
      - foo (replan 2)
      TXT

      assert_replan(test_content, expected_next_date_section)
    end

    context "fixed timestamp" do
      it "Should copy the timestamp from line time, if it's the only one" do
        # This is a variation of the standard time description, which is useful for intervals.
        #
        test_content = <<~TXT
            MON 20/SEP/2021
        - 12:30-13:00. foo (replan f 2)
        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - 12:30-13:00. foo

            WED 22/SEP/2021
        - 12:30-13:00. foo (replan f 2)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should set and copy the (explicit) timestamp from replan time, if it's the only one" do
        # This is a variation of the standard time description, which is useful for intervals.
        #
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan f12:00 2)
        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - foo

            WED 22/SEP/2021
        - 12:00. foo (replan f12:00 2)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should give priority to the replan timestamp" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - 12:30. foo (replan f14:00 2)
        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - 12:30. foo

            WED 22/SEP/2021
        - 14:00. foo (replan f14:00 2)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should overwrite an interval time, when the timestamp is set" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - 13:00-14:00. foo (replan f15:00 2)
        TXT

        # Recomputing the interval doesn't really work, as intervals are generally irregular.
        #
        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - 13:00-14:00. foo

            WED 22/SEP/2021
        - 15:00. foo (replan f15:00 2)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should require a timestamp" do
        # Trailing line is required, because we don't use assert_replan().
        #
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan f 2)

        TXT

        expect { subject.execute(test_content) }.to raise_error('Fixed timestamp is set, but no timestamp is provided: "- foo (replan f 2)"')
      end
    end # context "fixed timestamp"
  end # context "timestamp handling"

  # Other update-related functionality are in the other contexts.
  #
  context 'update (replan line)' do
    it "Should update the replan line on update" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan u 3)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - foobar

          THU 23/SEP/2021
      - foobar (replan u 3)
      TXT

      expect_any_instance_of(InputHelper)
        .to receive(:ask)
        .with("Enter the new description:", prefill: "foo")
        .and_return("foobar")

      assert_replan(test_content, expected_next_date_section)
    end

    it "Should update the replan line on full update" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan U 3)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - foobar

          THU 23/SEP/2021
      - foobar (replan U 3)
      TXT

      expect_any_instance_of(InputHelper)
        .to receive(:ask)
        .with("Enter the new description:", prefill: "foo (replan U 3)")
        .and_return("foobar (replan U 3)")

      assert_replan(test_content, expected_next_date_section)
    end
  end # context 'update (replan line)'

  context 'next' do
    context 'field weekday support' do
      # "current" is intended the european way.
      #
      it "Should set the day in the current week, accounting the semantic different with Ruby's start of the week" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan sun)
        TXT

        # This also ensures that the picked Sunday is the following one.
        #
        expected_next_date_section = <<~TXT
            SUN 26/SEP/2021
        - foo (replan sun)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      # `tue in N` is also supported, but since it's not useful, its "undocumented".
      #
      it "Should allow weekday+ to be supported as next occurrence" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan tue on tue+)
        TXT

        expected_next_date_section = <<~TXT
            TUE 28/SEP/2021
        - foo (replan tue)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should allow month/day to be supported as next occurrence" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan tue on dec/31)
        TXT

        expected_next_date_section = <<~TXT
            FRI 31/DEC/2021
        - foo (replan tue)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should allow day/month to be supported as next occurrence" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan tue on 31/dec)
        TXT

        expected_next_date_section = <<~TXT
            FRI 31/DEC/2021
        - foo (replan tue)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should assign the next year, when the month/day next occurrence is in the past" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan tue on jan/5)
        TXT

        expected_next_date_section = <<~TXT
            WED 05/JAN/2022
        - foo (replan tue)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it 'supports a once-off month/day occurrence with on' do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan o on dec/31)

        TXT

        expected_updated_content = <<~TXT
            MON 20/SEP/2021

            FRI 31/DEC/2021
        - foo
        -----
        -----
        -----
        -----

        TXT

        assert_replan(test_content, expected_updated_content, exact: true)
      end

      it 'rejects an invalid month/day occurrence with on' do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan tue on jun/31)

        TXT

        Timecop.freeze(ReplannerSpecHelper::CURRENT_DATE) do
          expect { subject.execute(test_content) }.to raise_error(Date::Error, 'invalid date')
        end
      end

      it "Should set the day in the following week, when the weekday matches the current day" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan mon)
        TXT

        expected_next_date_section = <<~TXT
            MON 27/SEP/2021
        - foo (replan mon)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should add one week, when the day is in the current week" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan sun+)
        TXT

        expected_next_date_section = <<~TXT
            SUN 03/OCT/2021
        - foo (replan sun+)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      # In order to avoid confusion, the `+` always add one week.
      #
      it "Should add one week, when the day is in the next week" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan mon+)
        TXT

        expected_next_date_section = <<~TXT
            MON 04/OCT/2021
        - foo (replan mon+)
        TXT

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should consider the event recurring, if it's update full with interval" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan U 2)
        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - bar

            WED 22/SEP/2021
        - bar (replan U 2)
        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U 2)")
          .and_return("bar (replan U 2)")

        assert_replan(test_content, expected_next_date_section)
      end

      it "Should consider the event recurring, if it's update full with weekday but not interval" do
        test_content = <<~TXT
            MON 20/SEP/2021
        - foo (replan U sun)
        TXT

        expected_next_date_section = <<~TXT
            MON 20/SEP/2021
        - bar

            WED 22/SEP/2021
        - bar (replan U wed)
        TXT

        expect_any_instance_of(InputHelper)
          .to receive(:ask)
          .with("Enter the new description:", prefill: "foo (replan U sun)")
          .and_return("bar (replan U wed)")

        assert_replan(test_content, expected_next_date_section)
      end
    end # context 'weekday support'

    it "Should copy an update full with interval and numeric next" do
      test_content = <<~TXT
          MON 20/SEP/2021
      - foo (replan U 3 in 2)
      TXT

      expected_next_date_section = <<~TXT
          MON 20/SEP/2021
      - foo

          WED 22/SEP/2021
      - foo (replan U 3 in 2)
      TXT

      expect_any_instance_of(InputHelper)
        .to receive(:ask)
        .with("Enter the new description:", prefill: "foo (replan U 3 in 2)")
        .and_return("foo (replan U 3 in 2)")

      assert_replan(test_content, expected_next_date_section, )
    end
  end # context 'next'
end # describe Replanner
