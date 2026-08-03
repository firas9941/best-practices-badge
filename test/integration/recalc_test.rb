# frozen_string_literal: true

# Copyright 2015-2017, the Linux Foundation, IDA, and the
# OpenSSF Best Practices badge contributors
# SPDX-License-Identifier: MIT

require 'test_helper'

# rubocop:disable Metrics/ClassLength
class RecalcTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  test 'Make sure recalc percentages only updates levels specified' do
    project = projects(:one)
    old_percentage = project.badge_percentage_1
    assert_equal 0, old_percentage, 'Old silver percentage wrong'
    # Update some columns without triggering percentage calculation
    # or change in updated_at
    assert_no_difference [
      'Project.find(projects(:one).id).badge_percentage_0',
      'Project.find(projects(:one).id).badge_percentage_1',
      'Project.find(projects(:one).id).badge_percentage_2',
      'Project.find(projects(:one).id).updated_at'
    ] do
      project.update_column(:crypto_weaknesses_status, 3) # Met
      project.update_column(:crypto_weaknesses_justification, 'It is good')
      project.update_column(:warnings_strict_status, 3) # Met
      project.update_column(:warnings_strict_justification, 'It is good')
    end
    # Run the update task, make sure updated_at and others don't change
    assert_no_difference [
      'Project.find(projects(:one).id).updated_at',
      'Project.find(projects(:one).id).badge_percentage_0',
      'Project.find(projects(:one).id).badge_percentage_2'
    ] do
      Project.update_all_badge_percentages(['1'])
    end
    # Check the badge percentage changed
    assert_not_equal(
      Project.find(projects(:one).id).badge_percentage_1,
      old_percentage
    )
  end

  # rubocop:disable Metrics/BlockLength
  test 'Make sure recalc percentages only updates levels affected' do
    project = projects(:one)
    old_percentage0 = project.badge_percentage_0
    old_percentage1 = project.badge_percentage_1
    assert_equal 1, old_percentage0, 'Old passing percentage wrong'
    assert_equal 0, old_percentage1, 'Old silver percentage wrong'
    # Update some columns without triggering percentage calculation
    # or change in updated_at
    assert_no_difference [
      'Project.find(projects(:one).id).badge_percentage_0',
      'Project.find(projects(:one).id).badge_percentage_1',
      'Project.find(projects(:one).id).badge_percentage_2',
      'Project.find(projects(:one).id).updated_at'
    ] do
      project.update_column(:crypto_weaknesses_status, 3) # Met
      project.update_column(:crypto_weaknesses_justification, 'It is good')
      project.update_column(:warnings_strict_status, 3) # Met
      project.update_column(:warnings_strict_justification, 'It is good')
    end
    # Run the update task, make sure updated_at and others don't change
    assert_no_difference [
      'Project.find(projects(:one).id).updated_at',
      'Project.find(projects(:one).id).badge_percentage_2'
    ] do
      # Level 2 does not depend on these keys
      # so it's percentage should not change
      Project.update_all_badge_percentages(Criteria.keys)
    end
    # Check the badge percentage changed
    assert_not_equal(
      Project.find(projects(:one).id).badge_percentage_0,
      old_percentage0,
      'passing badge percentage is supposed to change'
    )
    assert_not_equal(
      Project.find(projects(:one).id).badge_percentage_1,
      old_percentage1,
      'silver badge percentage is supposed to change'
    )
  end
  # rubocop:enable Metrics/BlockLength

  test 'Raises TypeError' do
    assert_raises(TypeError) { Project.update_all_badge_percentages('1') }
  end

  test 'Raises ArgumentError' do
    assert_raises(ArgumentError) do
      Project.update_all_badge_percentages(['3'])
    end
  end

  # --- update_all_badge_percentages loss-column tests ---

  test 'update_all_badge_percentages sets unreported_badge_loss on metal loss' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    Project.update_all_badge_percentages(['0'])
    assert_equal Sections::BADGE_LEVEL_RANK['passing'],
                 Project.find(project.id).unreported_badge_loss
  end

  test 'update_all_badge_percentages sets unreported_baseline_badge_loss on baseline loss' do
    project = projects(:one)
    project.update_column(:badge_percentage_baseline_1, 100)
    Project.update_all_badge_percentages(['baseline-1'])
    assert_equal Sections::BADGE_LEVEL_RANK['baseline-1'],
                 Project.find(project.id).unreported_baseline_badge_loss
  end

  test 'update_all_badge_percentages does not set columns when notify_losses: false' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    Project.update_all_badge_percentages(['0'], notify_losses: false)
    assert_equal 0, Project.find(project.id).unreported_badge_loss
  end

  # The attempt counters bound retries, so raising a flag must reset the
  # matching one.  Without this, a project that used up its attempts on
  # an earlier notification is permanently unnotifiable, and the next
  # genuine loss or warning is dropped in silence.  That is the failure
  # this whole repair exists to prevent, so it is asserted directly
  # rather than left to the retry logic that will read these columns.
  test 'update_all_badge_percentages resets loss_send_attempts on a loss' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    project.update_column(:loss_send_attempts, 5)
    Project.update_all_badge_percentages(['0'])
    assert_equal 0, Project.find(project.id).loss_send_attempts
  end

  test 'update_all_badge_percentages resets attempts on a baseline loss' do
    project = projects(:one)
    project.update_column(:badge_percentage_baseline_1, 100)
    project.update_column(:loss_send_attempts, 5)
    Project.update_all_badge_percentages(['baseline-1'])
    assert_equal 0, Project.find(project.id).loss_send_attempts
  end

  # A recalculation that loses nothing must leave the count alone; it
  # belongs to the notification still pending, not to the run.
  test 'update_all_badge_percentages leaves attempts alone without a loss' do
    project = projects(:one)
    project.update_column(:loss_send_attempts, 5)
    Project.update_all_badge_percentages(['0'])
    assert_equal 5, Project.find(project.id).loss_send_attempts
  end

  test 'update_all_badge_warnings resets warning_send_attempts' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    project.update_column(:warning_send_attempts, 5)
    Project.update_all_badge_warnings(Criteria.keys,
                                      effective_date: Time.zone.today + 30)
    assert_equal 0, Project.find(project.id).warning_send_attempts
  end

  # --- send_loss_notifications tests ---

  test 'send_loss_notifications sends email and clears column' do
    project = projects(:one)
    project.update_column(:unreported_badge_loss, 1) # rank of 'passing'
    assert_emails(1) do
      Project.send_loss_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_badge_loss
  end

  test 'send_loss_notifications sends baseline email and clears column' do
    project = projects(:one)
    project.update_column(:unreported_baseline_badge_loss, 1) # rank of 'baseline-1'
    assert_emails(1) do
      Project.send_loss_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_baseline_badge_loss
  end

  # Suppression defers rather than discards.  Clearing here would mean an
  # owner who re-enables notifications gets nothing, because no new flag
  # is raised unless the badge changes level again.
  test 'send_loss_notifications keeps the flag when notifications are off' do
    project = projects(:one)
    project.user.update_column(:important_notifications, false)
    project.update_column(:unreported_badge_loss, 1)
    assert_emails(0) do
      Project.send_loss_notifications
    end
    assert_equal 1, Project.find(project.id).unreported_badge_loss
    assert_nil Project.find(project.id).last_loss_sent_at
  end

  # The point of deferring: the notification is still there to deliver.
  test 'send_loss_notifications delivers once notifications are back on' do
    project = projects(:one)
    project.user.update_column(:important_notifications, false)
    project.update_column(:unreported_badge_loss, 1)
    assert_emails(0) do
      Project.send_loss_notifications
    end
    project.user.update_column(:important_notifications, true)
    assert_emails(1) do
      Project.send_loss_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_badge_loss
  end

  # The defect found while doing step 3b: the loop tested only that
  # encrypted_email was present, while the mailer also required an
  # address that decrypts and contains "@".  An owner failing only the
  # mailer's test was counted as emailed and had the flag cleared,
  # though no mail was ever created.
  test 'send_loss_notifications keeps the flag for an unusable address' do
    project = projects(:one)
    user = project.user
    user.email = 'no-at-sign'
    user.save!(validate: false)
    project.update_column(:unreported_badge_loss, 1)
    assert_emails(0) do
      assert_equal 0, Project.send_loss_notifications
    end
    assert_equal 1, Project.find(project.id).unreported_badge_loss
  end

  test 'send_loss_notifications skips email if badge already regained' do
    # perfect_passing has tiered_percentage >= 100, so badge_level = 'passing'.
    # Setting unreported_badge_loss = 1 (passing) means the loss is no longer
    # current — the badge was regained — so no email should be sent.
    project = projects(:perfect_passing)
    project.update_column(:unreported_badge_loss, 1)
    assert_emails(0) do
      Project.send_loss_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_badge_loss
  end

  test 'send_loss_notifications sets last_loss_sent_at' do
    project = projects(:one)
    project.update_column(:unreported_badge_loss, 1)
    assert_nil Project.find(project.id).last_loss_sent_at
    Project.send_loss_notifications
    assert_not_nil Project.find(project.id).last_loss_sent_at
  end

  # Idempotency. A second run must send nothing, because the first run
  # cleared the flag.  When clearing silently failed, the same email went
  # out every night for weeks; see docs/warning_failures.md.
  test 'send_loss_notifications does not repeat on a second run' do
    project = projects(:one)
    project.update_column(:unreported_badge_loss, 1)
    assert_emails(1) do
      Project.send_loss_notifications
    end
    assert_emails(0) do
      Project.send_loss_notifications
    end
  end

  test 'send_loss_notifications does not repeat baseline mail on a second run' do
    project = projects(:one)
    project.update_column(:unreported_baseline_badge_loss, 1)
    assert_emails(1) do
      Project.send_loss_notifications
    end
    assert_emails(0) do
      Project.send_loss_notifications
    end
  end

  # Notification bookkeeping must not disturb the edit flow.  If clearing a
  # flag bumped lock_version, an owner with the edit form already open would
  # be told their entry "changed since you started editing" when none of
  # their content had.
  test 'clearing a notification flag leaves lock_version alone' do
    project = projects(:one)
    project.update_column(:unreported_baseline_badge_warning, 1)
    before = Project.where(id: project.id).pick(:lock_version)
    assert_predicate before, :positive?, 'fixture must exercise a real lock'
    Project.send_warning_notifications
    assert_equal before, Project.where(id: project.id).pick(:lock_version)
  end

  test 'clearing a loss flag leaves lock_version alone' do
    project = projects(:one)
    project.update_column(:unreported_badge_loss, 1)
    before = Project.where(id: project.id).pick(:lock_version)
    Project.send_loss_notifications
    assert_equal before, Project.where(id: project.id).pick(:lock_version)
  end

  # Reaching the cap partway through a project must stop immediately: the
  # kind already handled is cleared, and the next kind of that same project
  # is left pending for the next run rather than being sent over the cap.
  test 'send_notifications stops at the cap partway through a project' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    project.update_column(:unreported_baseline_badge_warning, 1)
    sent = Project.send(
      :send_notifications, Project.where(id: project.id), 1,
      Project::NOTIFICATION_SERIES[:warning]
    ) { |_project, _user, _level, _suffix| :sent }
    assert_equal 1, sent
    fresh = Project.find(project.id)
    assert_equal 0, fresh.unreported_badge_warning
    assert_equal 1, fresh.unreported_baseline_badge_warning
  end

  # Column names are interpolated into the UPDATE, so anything that is not
  # a real column must be refused rather than reaching the database.
  test 'clear_notification_flag refuses a name that is not a column' do
    assert_raises(ArgumentError) do
      Project.send(
        :clear_notification_flag, projects(:one),
        'unreported_badge_loss = 0; DROP TABLE projects; --' => 1
      )
    end
    assert_raises(ArgumentError) do
      Project.send(:clear_notification_flag, projects(:one), no_such_column: 1)
    end
  end

  # The failure path must be noisy.  A bookkeeping write that quietly
  # changed nothing is exactly what let the same emails go out night after
  # night; see docs/warning_failures.md.
  test 'clear_notification_flag reports a write that matches no rows' do
    missing = Project.new
    missing.id = -1 # no such row, so the update matches nothing
    logged = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)
    begin
      assert_not Project.send(
        :clear_notification_flag, missing, unreported_badge_loss: 0
      )
    ensure
      Rails.logger = original_logger
    end
    assert_match(/affected 0 rows/, logged.string)
    assert_match(/project -1/, logged.string)
  end

  # A block that answers in the old Boolean vocabulary must fail loudly.
  # Read as an outcome, "true" is simply unknown, and the quiet reading of
  # an unknown answer is "no mail was sent", which would undercount
  # silently and, once outcomes drive clearing, mishandle the flag.
  test 'send_notifications rejects an unknown outcome' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    error =
      assert_raises(ArgumentError) do
        Project.send(
          :send_notifications, Project.where(id: project.id), 1,
          Project::NOTIFICATION_SERIES[:warning]
        ) { |_project, _user, _level, _suffix| true }
      end
    assert_match(/Unknown notification outcome/, error.message)
  end

  # Every outcome the vocabulary defines must be handled, not just the
  # ones today's two mailers happen to return.
  test 'send_notifications counts only the sent outcome' do
    project = projects(:one)
    Project::NOTIFICATION_OUTCOMES.each do |outcome|
      project.update_column(:unreported_badge_warning, 1)
      sent = Project.send(
        :send_notifications, Project.where(id: project.id), 1,
        Project::NOTIFICATION_SERIES[:warning]
      ) { |_project, _user, _level, _suffix| outcome }
      assert_equal (outcome == :sent ? 1 : 0), sent, "outcome #{outcome}"
      # A suppressed notification is kept for a later run; the other two
      # are finished with, one way or the other.
      assert_equal (outcome == :suppressed ? 1 : 0),
                   Project.find(project.id).unreported_badge_warning,
                   "outcome #{outcome}"
    end
  end

  # The counter must report mail actually sent.  perfect_passing has
  # regained the level, so send_loss_email returns :not_relevant and
  # nothing is sent; the count previously included such projects anyway.
  test 'send_loss_notifications does not count declined mail' do
    project = projects(:perfect_passing)
    project.update_column(:unreported_badge_loss, 1)
    assert_equal 0, Project.send_loss_notifications
  end

  # --- update_all_badge_warnings tests ---

  test 'update_all_badge_warnings sets unreported_badge_warning on metal loss' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    Project.update_all_badge_warnings(Criteria.keys,
                                      effective_date: Time.zone.today + 30)
    assert_equal Sections::BADGE_LEVEL_RANK['passing'],
                 Project.find(project.id).unreported_badge_warning
  end

  test 'update_all_badge_warnings sets badge_warning_effective_date' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    future_date = Time.zone.today + 30
    Project.update_all_badge_warnings(Criteria.keys,
                                      effective_date: future_date)
    assert_equal future_date,
                 Project.find(project.id).badge_warning_effective_date
  end

  test 'update_all_badge_warnings does not change badge_percentage_0 in DB' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    Project.update_all_badge_warnings(Criteria.keys,
                                      effective_date: Time.zone.today + 30)
    assert_equal 100, Project.find(project.id).badge_percentage_0
  end

  test 'update_all_badge_warnings sets unreported_baseline_badge_warning' do
    project = projects(:one)
    project.update_column(:badge_percentage_baseline_1, 100)
    Project.update_all_badge_warnings(['baseline-1'],
                                      effective_date: Time.zone.today + 30)
    assert_equal Sections::BADGE_LEVEL_RANK['baseline-1'],
                 Project.find(project.id).unreported_baseline_badge_warning
  end

  test 'update_all_badge_warnings with report: true prints project info' do
    project = projects(:one)
    project.update_column(:badge_percentage_0, 100)
    project.update_column(:tiered_percentage, 100)
    assert_output(/Project #{project.id}/) do
      Project.update_all_badge_warnings(Criteria.keys,
                                        effective_date: Time.zone.today + 30,
                                        report: true)
    end
    # Must not write warning columns in report mode
    assert_equal 0, Project.find(project.id).unreported_badge_warning
  end

  test 'update_all_badge_warnings report: true prints baseline info' do
    project = projects(:one)
    project.update_column(:badge_percentage_baseline_1, 100)
    assert_output(/\(baseline\)/) do
      Project.update_all_badge_warnings(['baseline-1'],
                                        effective_date: Time.zone.today + 30,
                                        report: true)
    end
    # Must not write warning columns in report mode
    assert_equal 0, Project.find(project.id).unreported_baseline_badge_warning
  end

  # --- send_warning_notifications tests ---

  test 'send_warning_notifications sends email and clears column' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1) # rank of 'passing'
    assert_emails(1) do
      Project.send_warning_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_badge_warning
  end

  test 'send_warning_notifications sends baseline email and clears column' do
    project = projects(:one)
    project.update_column(:unreported_baseline_badge_warning, 1)
    assert_emails(1) do
      Project.send_warning_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_baseline_badge_warning
  end

  test 'send_warning_notifications keeps the flag when notifications are off' do
    project = projects(:one)
    project.user.update_column(:important_notifications, false)
    project.update_column(:unreported_badge_warning, 1)
    assert_emails(0) do
      Project.send_warning_notifications
    end
    assert_equal 1, Project.find(project.id).unreported_badge_warning
    assert_nil Project.find(project.id).last_warning_sent_at
  end

  test 'send_warning_notifications sets last_warning_sent_at' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    assert_nil Project.find(project.id).last_warning_sent_at
    Project.send_warning_notifications
    assert_not_nil Project.find(project.id).last_warning_sent_at
  end

  test 'send_warning_notifications does not repeat on a second run' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    assert_emails(1) do
      Project.send_warning_notifications
    end
    assert_emails(0) do
      Project.send_warning_notifications
    end
  end

  test 'send_warning_notifications does not repeat baseline mail on a second run' do
    project = projects(:one)
    project.update_column(:unreported_baseline_badge_warning, 1)
    assert_emails(1) do
      Project.send_warning_notifications
    end
    assert_emails(0) do
      Project.send_warning_notifications
    end
  end

  # Relevance guard.  A warning announces a deadline, so once that date
  # is past the message would state a deadline in the past.  The 11 stale
  # flags of 2026-07-31 had to be cleared by hand for exactly this
  # reason; see docs/warning_failures.md.
  test 'send_warning_notifications skips a warning whose date has passed' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    project.update_column(:badge_warning_effective_date,
                          Time.zone.today - 1)
    assert_emails(0) do
      Project.send_warning_notifications
    end
    assert_equal 0, Project.find(project.id).unreported_badge_warning
  end

  test 'send_warning_notifications skips a stale baseline warning' do
    project = projects(:one)
    project.update_column(:unreported_baseline_badge_warning, 1)
    project.update_column(:badge_warning_effective_date,
                          Time.zone.today - 1)
    assert_emails(0) do
      Project.send_warning_notifications
    end
    assert_equal 0,
                 Project.find(project.id).unreported_baseline_badge_warning
  end

  # The deadline is the last day the warning is true, not the first day
  # it is stale, so a warning due today is still worth sending.
  test 'send_warning_notifications still warns on the effective date' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    project.update_column(:badge_warning_effective_date, Time.zone.today)
    assert_emails(1) do
      Project.send_warning_notifications
    end
  end

  # Deliberate: with no date recorded we cannot show the deadline has
  # passed, and skipping would discard the notification silently, which
  # is the failure this whole repair exists to stop.  Warn instead.
  test 'send_warning_notifications warns when no date was recorded' do
    project = projects(:one)
    project.update_column(:unreported_badge_warning, 1)
    assert_nil Project.find(project.id).badge_warning_effective_date
    assert_emails(1) do
      Project.send_warning_notifications
    end
  end
end
# rubocop:enable Metrics/ClassLength
