# frozen_string_literal: true

# Copyright the Linux Foundation and the
# OpenSSF Best Practices badge contributors
# SPDX-License-Identifier: MIT

require 'test_helper'

# Full round-trip tests for docs/login-session-implementation.md section 15
# and docs/login-session-simplify.md Part 2: a stashed pending resubmission
# must survive both local login and GitHub OAuth login (which leaves the
# site entirely and comes back), because counter_fixation's reset_session
# runs unconditionally on every login attempt, success or failure. Since
# docs/login-session-18.md's "Step 21", the token rides the login
# redirect's own request params, the same way a real browser's login-form
# hidden field or GitHub auth link would carry it, rather than session;
# these tests thread it through that way instead of reading it back from
# session mid-flow.
#
# Since Part 2, there is no dedicated resume page: a forced re-login sends
# the user back to the resource's own edit page
# (ApplicationController#overlay_pending_resubmission!), pre-filled with
# the stashed values, and a normal resubmit of that same form is what
# consumes the stash. The stash-creating PATCH in these tests targets each
# project's own edit path, the same URL its real edit form posts to, on
# purpose: overlay_pending_resubmission! only restores a stash whose
# resubmit_path matches that exact page. (Literal path strings, not
# edit_project_section_path/user_path: those need an explicit locale: to
# resolve outside of an actual request/view context, where
# ApplicationController#default_url_options isn't there to supply one.)
# rubocop:disable Metrics/ClassLength
class PendingResubmissionTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:one)
    @user = users(:test_user) # local user, owns @project
    # A literal path string, not edit_project_section_path(@project,
    # 'passing'): that helper needs an explicit locale: to resolve
    # correctly outside of an actual request/view context (where
    # ApplicationController#default_url_options isn't there to supply
    # one), and a literal path is simpler than threading locale: through
    # every call.
    @edit_path = "/en/projects/#{@project.id}/passing/edit"
    @user_path = "/en/users/#{@user.id}"
    @user_edit_path = "#{@user_path}/edit"
  end

  test 'local login carries the stash through and resubmitting it saves and consumes it' do
    new_name = "#{@project.name}_resubmitted"

    patch @edit_path, params: { project: { name: new_name } }
    token = pending_resubmission_token_from_redirect
    assert_not_nil token
    assert_nil session[:pending_resubmission_token] # not written until login succeeds

    log_in_with_token(token)
    assert_redirected_to @edit_path
    # counter_fixation resets the session on every login attempt; confirm
    # the token actually survived via this login's own request param,
    # rather than this redirect happening to be right for some other
    # reason.
    assert_equal token, session[:pending_resubmission_token]

    follow_redirect!
    assert_response :success
    assert_select "input[name='project[name]'][value='#{new_name}']"
    assert_select "input[type='hidden'][name='pending_resubmission_token'][value='#{token}']"
    assert_includes @response.body, 'We filled in what you typed below'

    # Submit the real edit form as rendered: the same fields, plus the
    # hidden pending_resubmission_token field it now carries.
    patch @edit_path, params: {
      project: { name: new_name }, pending_resubmission_token: token
    }
    @project.reload
    assert_equal new_name, @project.name

    # docs/login-session-evaluation.md finding #4: resubmitting is what
    # finally consumes the stash
    # (ApplicationController#finalize_pending_resubmission), not the
    # earlier GET that rendered it.
    assert_not PendingResubmission.exists?(hashed_random_id: PendingResubmission.digest(token))
    assert_nil session[:pending_resubmission_token]
  end

  test 'revisiting after a closed tab (a fresh GET) still shows the stash' do
    # docs/login-session-evaluation.md finding #4: the old design destroyed
    # the row and session key on the first GET, so a closed tab (before
    # ever resubmitting) lost the edit for good. A second, independent GET
    # (e.g. "reopen closed tab", a fresh request, not a cached page) must
    # still show it.
    new_name = "#{@project.name}_resubmitted"
    patch @edit_path, params: { project: { name: new_name } }
    log_in_with_token(pending_resubmission_token_from_redirect)
    follow_redirect! # first view of the edit page; tab "closes" here

    get @edit_path
    assert_response :success
    assert_select "input[name='project[name]'][value='#{new_name}']"

    patch @edit_path, params: {
      project: { name: new_name }, pending_resubmission_token: session[:pending_resubmission_token]
    }
    @project.reload
    assert_equal new_name, @project.name
  end

  test 'a failed login attempt does not lose the stash' do
    patch @edit_path, params: { project: { name: 'attempt' } }
    token = pending_resubmission_token_from_redirect
    assert_not_nil token

    log_in_with_token(token, password: 'wrong-password')
    assert_response :success # re-renders the login form; login failed
    # Login failed, so this never reached successful_login; the token
    # survives only because the re-rendered form echoes back this same
    # request's own pending_resubmission_token param, ready for a retry
    # with the correct password, not via session.
    assert_select "input[type='hidden'][name='session[pending_resubmission_token]']" \
                  "[value='#{token}']"
    assert PendingResubmission.exists?(hashed_random_id: PendingResubmission.digest(token))
  end

  test 'github oauth login carries the stash across the round trip' do
    patch @edit_path, params: { project: { name: 'via github' } }
    token = pending_resubmission_token_from_redirect
    assert_not_nil token

    github_user = users(:github_user)
    # Both github-provider fixtures leave :uid unset (NULL for both), so
    # give it a real one first rather than relying on the mock's fallback
    # to disambiguate.
    github_user.update!(uid: 'github-test-uid')
    OmniAuth.config.test_mode = true
    OmniAuth.config.add_mock(
      :github,
      'provider' => 'github',
      'uid' => github_user.uid,
      'credentials' => { 'token' => 'test_token' },
      'info' => {
        'name' => github_user.name,
        'nickname' => github_user.nickname,
        'email' => github_user.email
      }
    )
    # Hits the request phase first, with both the token and return_to as
    # query params the same way the login page's "Log in with GitHub" link
    # builds it, so OmniAuth's own session['omniauth.params'] round trip
    # actually carries them across the redirect to GitHub and back, rather
    # than this test jumping straight to the callback and skipping that
    # entirely. POST, not GET: OmniAuth 2.x's default
    # allowed_request_methods is [:post] only, matching this app's own
    # link (method: 'post'); a GET here just 404s. Both ride the URL's own
    # query string, not the params: hash, since Rails' post/params:
    # encodes that into the request body, but OmniAuth reads request.GET
    # (query string only), the same as the real link.
    return_to = ERB::Util.url_encode(query_param_from_redirect('return_to'))
    post "/auth/github?pending_resubmission_token=#{ERB::Util.url_encode(token)}" \
         "&return_to=#{return_to}"
    assert_response :redirect
    follow_redirect!
    assert_redirected_to @edit_path
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  test 'merely viewing the edit page the stash redirect sends you to does not destroy it' do
    # Regression test for a real incident on staging (2026-09-12), from
    # before Part 2: ApplicationController#finalize_pending_resubmission
    # used to be a before_action, firing on ANY request carrying a
    # pending_resubmission_token param. That's long fixed (finalize_
    # pending_resubmission is now only ever called explicitly from a
    # confirmed-successful save), but this keeps the regression covered
    # end to end: simply landing on and viewing the edit page a stash
    # redirects to must never destroy it.
    patch @edit_path, params: { project: { name: 'never resubmitted yet' } }
    token = pending_resubmission_token_from_redirect
    assert_not_nil token

    log_in_with_token(token)
    follow_redirect! # GET the edit page the stash redirect sent us to
    assert_response :success
    assert PendingResubmission.exists?(hashed_random_id: PendingResubmission.digest(token))
  end

  test 'a successful resubmission destroys the stash' do
    new_name = "#{@project.name}_resubmitted"
    patch @edit_path, params: { project: { name: new_name } }
    token = pending_resubmission_token_from_redirect
    log_in_with_token(token)
    follow_redirect!

    patch @edit_path, params: {
      project: { name: new_name }, pending_resubmission_token: token
    }
    @project.reload
    assert_equal new_name, @project.name
    assert_not PendingResubmission.exists?(hashed_random_id: PendingResubmission.digest(token))
  end

  test 'a resubmission that fails validation keeps the stash' do
    # finalize_pending_resubmission must only fire once we KNOW the change
    # was accepted (ProjectsController#successful_update only runs inside
    # `if @project.save`), not merely because a PATCH carrying the token
    # arrived: otherwise a validation failure on resubmission would lose
    # the draft for good, exactly what this whole feature exists to
    # prevent. TextValidator (app/validators/text_validator.rb) rejects
    # control characters, giving a reliable, unconditional validation
    # failure regardless of the project's other field values.
    patch @edit_path, params: { project: { name: 'will retry' } }
    token = pending_resubmission_token_from_redirect
    log_in_with_token(token)
    follow_redirect!

    patch @edit_path, params: {
      project: { name: "bad\x01name" }, pending_resubmission_token: token
    }
    assert_response :success # re-renders :edit; the save failed
    assert PendingResubmission.exists?(hashed_random_id: PendingResubmission.digest(token))
  end

  test 'a successful user-profile resubmission destroys the stash too' do
    # UsersController#update's `if @user.save` branch finalizes a pending
    # resubmission the same way ProjectsController#successful_update does;
    # this exercises that call site specifically; the tests above only
    # cover the ProjectsController one. Reuses the 'foo@bar.com' email
    # change and its matching VCR cassette from
    # test/integration/users_edit_test.rb's "successful edit" test: any
    # successful save by a local-provider user calls User#gravatar_exists?
    # (an HTTP HEAD to Gravatar), whether or not this particular update
    # actually changes the email, so the resubmit step needs a cassette
    # recorded for whatever email ends up saved.
    new_name = "#{@user.name}_resubmitted"
    # return_to: matches the hidden field users/edit.html.erb now carries
    # (this PATCHes directly rather than actually rendering and submitting
    # that form, so it has to supply what the form would have supplied).
    patch @user_path, params: { user: { name: new_name }, return_to: @user_edit_path }
    token = pending_resubmission_token_from_redirect
    assert_not_nil token

    log_in_with_token(token)
    assert_redirected_to @user_edit_path
    follow_redirect!
    assert_select "input[name='user[name]'][value='#{new_name}']"

    VCR.use_cassette('successful_edit_-_name_email') do
      patch @user_path, params: {
        user: { name: new_name, email: 'foo@bar.com' }, pending_resubmission_token: token
      }
    end
    @user.reload
    assert_equal new_name, @user.name
    assert_not PendingResubmission.exists?(hashed_random_id: PendingResubmission.digest(token))
  end

  test 'shows the sensitive-fields-dropped warning when email or password was stripped' do
    patch @user_path, params: {
      user: { name: @user.name, email: @user.email }, return_to: @user_edit_path
    }
    log_in_with_token(pending_resubmission_token_from_redirect)
    follow_redirect!
    assert_response :success
    # Not "couldn't": t() output is HTML-escaped by ERB, so the rendered
    # apostrophe is "&#39;", not "'". Assert on a stretch without one.
    assert_includes @response.body, 'please re-enter it separately if needed'
  end

  test 'a stash for a different page is not overlaid onto this one' do
    # overlay_pending_resubmission! matches on resubmit_path, not merely
    # "does this session have any stash at all": a stash from editing one
    # project must never bleed into a different project's edit page.
    other_project = projects(:no_repo)
    patch @edit_path, params: { project: { name: 'for project one only' } }
    log_in_with_token(pending_resubmission_token_from_redirect)
    follow_redirect!

    get "/en/projects/#{other_project.id}/passing/edit"
    assert_response :success
    assert_not_includes @response.body, 'for project one only'
    assert_not_includes @response.body, 'We filled in what you typed below'
  end

  test 'a login without its own pending_resubmission_token never resumes a leftover one' do
    # Regression guard for the cross-user disclosure docs/login-session-18.md
    # "Step 21" closes: on a shared browser, an earlier abandoned stash must
    # not be resumed by a later, unrelated login that never carried its own
    # pending_resubmission_token param.
    patch @edit_path, params: { project: { name: 'someone else' } }
    assert_not_nil pending_resubmission_token_from_redirect

    post login_path, params: {
      session: { email: @user.email, password: 'password', provider: 'local' }
    }
    assert_response :redirect
    assert_nil session[:pending_resubmission_token]
  end

  private

  # Reads one query param from the most recent response's redirect
  # location, the same way a browser reads it off the URL it was sent to
  # rather than by peeking at session.
  def query_param_from_redirect(name)
    Rack::Utils.parse_nested_query(URI.parse(response.location).query)[name]
  end

  def pending_resubmission_token_from_redirect
    query_param_from_redirect('pending_resubmission_token')
  end

  # Logs @user in locally, carrying the given pending_resubmission_token
  # and this same redirect's own return_to forward as this login request's
  # own params (docs/login-session-18.md "Step 21"), the same way a real
  # login form's two hidden fields both get submitted together. Reads
  # return_to from the current response, so call this right after
  # extracting token from that same response, before anything else changes
  # it.
  def log_in_with_token(token, password: 'password')
    post login_path, params: {
      session: {
        email: @user.email, password: password, provider: 'local',
        pending_resubmission_token: token,
        return_to: query_param_from_redirect('return_to')
      }
    }
  end
end
# rubocop:enable Metrics/ClassLength
