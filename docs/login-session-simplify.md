# Simplifying the pending-resubmission resume UX

<!-- SPDX-License-Identifier: (MIT OR CC-BY-3.0+) -->

## Status

Not yet implemented. Staging validation of the underlying mechanism is
done (2026-09-13): with a clean test (revoke the `LoginSession`
server-side via `rake login_sessions:revoke[id]`, then submit the
still-open tab with no reload in between, so the tab's CSRF token stays
valid), the stash-and-resume round trip worked end to end: the PATCH was
correctly stashed, the login redirect carried the token, and the resume
page showed the stashed data. The foundation this plan simplifies is
confirmed working.

That same validation session also surfaced a real, separate problem,
addressed first below since it's small and independent of the main
redesign.

## Part 1: a friendly message when a stale tab's CSRF token was invalidated by logging out elsewhere

Found during staging validation (2026-09-13): logging out in one tab
calls `SessionsHelper#log_out`, which calls `reset_session`
(sessions_helper.rb:300). That clears `session[:_csrf_token]`, the secret
behind every CSRF token already embedded in any other tab's rendered
forms. Submitting one of those other, now-stale tabs raises
`ActionController::InvalidAuthenticityToken` (`protect_from_forgery with:
:exception`, application_controller.rb:77) before any of our own
before_actions run, so `redirect_unauthenticated_edit_attempt?` never gets
a chance to stash anything. The user just sees Rails' generic
`public/422.html`, "The change you wanted was rejected."

This is unrelated to (and unaffected by) both the already-shipped
`finalize_pending_resubmission` fix and Part 2 below: none of the other
forced-logout triggers this feature already handles (idle timeout,
absolute-cap expiry, admin revocation, password change elsewhere, the
one-time deploy-triggered mass logout) touch this browser's session
cookie or CSRF secret at all. An explicit `log_out` is the only one of
these that calls `reset_session` in the *same* browser, which is exactly
why it behaves differently. Our test suite never caught this either:
`config/environments/test.rb:49` sets `allow_forgery_protection = false`,
so no test (including the ones added for the `finalize_
pending_resubmission` fix) ever exercises a real CSRF check.

**Decision**: don't weaken CSRF protection to try to preserve the stale
tab's data. `stash_pending_resubmission` only requires being logged out,
so a code path that accepted a CSRF-failed submission and stashed it
anyway would just as readily accept a genuine cross-site-forged request
(which raises the identical exception, since an attacker can't know the
real secret either) and hand it back to the victim as a click-to-resume
page on their next login. That tradeoff isn't worth the UX gain for what
is, after all, a case the user's own explicit action caused.

Instead: add `rescue_from ActionController::InvalidAuthenticityToken` (or
a narrower, PATCH/POST-only check via a `before_action` wrapper) to
`ApplicationController`, and redirect to login with a clear explanatory
flash, reusing the existing `@auto_logged_out`-style messaging
(`redirect_to_login_stashing`'s `t('sessions.auto_logged_out')` flash is
the right shape to match). No attempt to stash or preserve the submitted
data; just replace the confusing generic 422 page with the same friendly
"you were logged out, please log in again" message the other
forced-logout cases already show.

Implementation note to check: `protect_from_forgery` applies uniformly
regardless of request format, so a blanket `rescue_from` that always
`redirect_to`s would also fire for a `format.json` request. Check whether
that matters for any current JSON-format action before assuming an HTML
redirect is always the right response (`respond_to` on the format may be
needed).

## Part 2: reuse the normal edit pages instead of a dedicated resume page (the main course)

### Problem with the current design

When a forced re-login stashes an in-progress edit
(`docs/login-session-implementation.md` section 15), the user is sent to
a dedicated `GET /pending_resubmissions` page: a generic, hand-built form
that echoes the stashed fields back as opaque hidden inputs and a single
"Resume" button. It works, but:

- It's a second UI the user has never seen before, with no context: they
  can't review what they're about to submit in the actual form, minus
  whatever sensitive fields got dropped.
- It's a whole extra controller, view, and route to maintain
  (`PendingResubmissionsController`, `pending_resubmissions/show.html.erb`,
  its route) for something we already have controllers and views for: the
  ordinary edit pages (`ProjectsController#edit`, `UsersController#edit`).

Goal: after a forced re-login, land the user back on the real edit page,
pre-filled with their attempted (unsaved) changes, so they review them in
context and hit the normal Save button. Do this with the least possible
code, not by adding a parallel mechanism.

### Guiding principle

Prefer "a form provides the data it already has, so a later step can just
read it" over "a later step re-derives or looks up the data it needs."
Concretely: an override value from the request, falling back to a
computed default, rather than a new lookup table or a new column that has
to be populated, stored, and kept in sync.

This is the same shape `return_to` already uses today
(`request.original_fullpath` as the default, an explicit
`params[:return_to]` if the request supplies one): extend that existing
mechanism instead of building a second one.

### Why a naive fix doesn't quite work

The "page to redisplay" can't always be derived from the failed PATCH's
own URL:

- Projects' main edit forms (`_form_1`, `_form_0`, `_form_2`,
  `_form_baseline`) post to `edit_project_section_path(project,
  criteria_level)`, the same URL Rails routes for both GET and PATCH
  (`config/routes.rb:172-180`, deliberately shared "so forms can submit
  here and the address bar stays at /edit"). For these, `request.
  original_fullpath` at stash time already is the right redisplay URL.
- `users/edit.html.erb` uses `form_for(@user)`, which posts to the plain
  RESTful `/en/users/:id`, not `/en/users/:id/edit`. Wrong page if we just
  reuse the request path.
- `_form_permissions.html.erb` posts to `update_project_path(project,
  section: 'permissions')`, not `edit_project_section_path(project,
  'permissions')`. Also wrong if reused as-is.

So the fallback default (today's `request.original_fullpath`) is right
for most Project edits and wrong for Users and the permissions sub-form.
Rather than special-casing controllers, let each form say what it is.

### The plan

#### 1. Let a form override `return_to`

`ApplicationController#redirect_to_login_stashing` (application_
controller.rb:945) currently does:

```ruby
login_params = { return_to: request.original_fullpath }
```

Change to prefer an explicit value the form supplied:

```ruby
login_params = { return_to: params[:return_to].presence || request.original_fullpath }
```

`return_to_path` is already passed through `valid_return_path?`
(sessions_helper.rb:420-424) further down the login pipeline exactly as
it is today. That's an open-redirect guard, not an authorization check:
it only confirms the path is server-relative (no protocol-relative `//`)
and isn't a login/signup loop; it says nothing about whether the
requester can do anything at that path. That's fine here because a
redirect only sends the user's *own* browser somewhere; the page they
land on enforces its own authorization exactly as it would for direct
navigation. The submitter already fully controls `request.
original_fullpath` by choosing what URL to POST/PATCH to in the first
place, so letting them also state `return_to` explicitly grants no new
capability.

(Automation proposals, `docs/automation-proposals.md`, already rely on
this exact same property for a *different* case: an unauthenticated GET
to an edit URL carrying proposal query params stores the full URL as
`return_to` and redirects to login, per that doc's "Authentication Flow"
section; after login the user lands back on that URL, and *that* page's
own authorization check decides whether they may actually edit it. This
change doesn't touch that flow: it's a GET, never a PATCH, so it never
reaches `stash_pending_resubmission` at all, and automation-proposal URLs
never set their own `return_to` param, so the new `params[:return_to]`
preference here never has anything to override for them.)

#### 2. Add the hidden field only where the default is wrong

- `app/views/users/edit.html.erb`: add
  `hidden_field_tag :return_to, edit_user_path(@user)` inside the form.
- `app/views/projects/_form_permissions.html.erb`: add
  `hidden_field_tag :return_to, edit_project_section_path(project, 'permissions')`.

Leave `_form_1`/`_form_0`/`_form_2`/`_form_baseline` alone: their default
is already correct. (Adding it there too would be harmless
belt-and-braces, but isn't required; skip it to keep the diff minimal
unless review finds a reason to want it.)

#### 3. Simplify `redirect_after_login`

`SessionsController#redirect_after_login` (sessions_controller.rb:164-177)
currently special-cases the resubmission redirect:

```ruby
def redirect_after_login(return_to_path)
  if session[:pending_resubmission_token].present?
    redirect_to pending_resubmission_path
  elsif return_to_path.present? && valid_return_path?(return_to_path)
    redirect_to return_to_path, allow_other_host: false
  else
    redirect_back_or root_url
  end
end
```

Once `return_to` always carries the right page (edit or otherwise), the
first branch is redundant: a stashed resubmission's `return_to` already
points at the right edit page, so it falls straight into the second
branch. Delete the `pending_resubmission_token` branch entirely; this
method goes back to what it was before section 15 added it.

#### 4. Overlay the stash in the edit action, render the normal template

In `ProjectsController#edit` and `UsersController#edit`: if
`session[:pending_resubmission_token]` is present, look up the stash and
compare `pending.resubmit_path` against the exact path *this resource's
own form would submit to* (i.e. the same route-helper call the form
partial already uses to build its `url:`), not against `request.path` or
`request.method`. If they match, apply the stashed (unprefixed) fields
onto the in-memory model with `assign_attributes` (never save) before
rendering the existing edit template unchanged. Add a flash explaining
what happened (reusing the existing `sensitive_fields_dropped` warning
text where applicable).

This is the same pattern automation proposals already use for a
different reason (`docs/automation-proposals.md`: "loaded into the
in-memory project object for display in the edit form... not saved to
the database until the user explicitly submits the form"), which is
reassuring prior art that "overlay unsaved values onto the model, render
the normal template" is already a proven, idiomatic approach in this
codebase.

Comparing against `request.path` instead would be a real bug, not just
imprecise: for Projects' main forms `request.path` (the GET edit page)
happens to equal `edit_project_section_path(@project, @criteria_level)`,
the same URL their form posts to, so it would work there by coincidence.
It would silently never match for `UsersController#edit` (whose form
posts to `user_path(@user)`, not `edit_user_path(@user)`) or for the
permissions sub-form (whose stash's `resubmit_path` is
`update_project_path(project, section: 'permissions')`, not
`edit_project_section_path(project, 'permissions')`), exactly the two
cases Part 2's "why a naive fix doesn't quite work" section above already
flags. Comparing `resubmit_method` against the edit action's own request
method is also meaningless (it's a GET showing the form; the stash's
`resubmit_method` is always the PATCH/PUT the form itself will use), so
drop that comparison rather than implement it. Each controller already
knows its own form's target (`edit_project_section_path(@project,
@criteria_level)` for Projects, `user_path(@user)` for Users), so this is
a value each `#edit` action passes to the shared helper, not something
derived from the current GET request.

This needs a small shared helper (e.g. on `ApplicationController`, called
from both `#edit` actions) so the match/overlay logic exists once, not
twice.

#### 5. Let the edit action hand the token back to the same form

While overlaying (step 4), the controller already has the token. Add one
more conditional hidden field to the form at that point:
`hidden_field_tag :pending_resubmission_token, @pending_resubmission_token
if @pending_resubmission_token`. This is the same "provide the data now,
while you have it" idea applied to the destroy side: `finalize_
pending_resubmission` (application_controller.rb:909) stays exactly as it
is today, still only reading an explicit `params[:pending_resubmission_
token]`, still only called from the confirmed-success branches
(`ProjectsController#successful_update`, `UsersController#update`'s
`if @user.save`) per the already-shipped fix. No behavior change there,
and no need for the "session-driven, destroys on any successful save"
broadening considered earlier.

#### 6. Delete the now-unused resume page

- `app/controllers/pending_resubmissions_controller.rb`
- `app/views/pending_resubmissions/show.html.erb`
- Its route in `config/routes.rb`
- `pending_resubmission_path`/`pending_resubmission_url` references
- Most of `test/controllers/pending_resubmissions_controller_test.rb`
  (the security-regression test about never reading an identifier from
  params has no equivalent surface left to test once the controller is
  gone; confirm nothing else in that file still applies before deleting
  it outright)

### What does NOT change

- `PendingResubmission` the model/table: same five real columns
  (`resubmit_path`, `resubmit_method`, `params_json`,
  `sensitive_fields_dropped`, `hashed_random_id`). No migration, because
  the redisplay URL travels via `return_to` (already fully plumbed
  through the login flow), not via a new stored column.
- `PendingResubmission.stash_for` / `#find_by_token` / `.digest` /
  `.purge_stale`: unchanged.
- `ApplicationController#stash_pending_resubmission`: unchanged.
- `ApplicationController#finalize_pending_resubmission`: unchanged (still
  explicit-param-driven, still only called from a confirmed-success
  branch).
- The HMAC-token-keyed lookup design (docs/login-session-18.md step 18):
  unchanged; this plan is only about UI/redirect plumbing, not the
  anti-guessing property.

## Sequencing

1. **Done** (2026-09-13): validated the stash-and-resume mechanism on
   staging via a clean revoke-then-submit-without-reloading test.
2. Implement Part 1 (the CSRF-message fix). Small, independent, low-risk.
3. Implement Part 2 (the main redesign, steps 1-6 above).
4. Update `docs/login-session-implementation.md` section 15 to match (it
   currently documents the dedicated resume-page design), and mention the
   CSRF-invalidation edge case from Part 1 there too.

## Background: pre-implementation review (2026-09-13)

Recorded here, after the steps to execute, since it's background reasoning
to fall back on if a question comes up later, not something to act on
directly.

### Security

Neither part weakens an existing security property:

- **Part 1**: `rescue_from ActionController::InvalidAuthenticityToken`
  only runs *after* `protect_from_forgery` has already raised and blocked
  the request; the controller action never executes either way. This is a
  presentation change (a redirect and a flash instead of the generic 422
  page), not a change to what gets rejected.
- **Part 2 step 1** (`return_to` override): still passes through
  `valid_return_path?` exactly as today, which only forbids off-site or
  protocol-relative targets. Whoever submits the PATCH already fully
  controls `request.original_fullpath` (today's default), so letting them
  state `return_to` explicitly grants no new capability. The real
  authorization check happens when the target page loads, same as always.
- **Part 2 step 4** (overlay): uses the same unguessable, HMAC-digested
  token that already exists (docs/login-session-18.md step 18, untouched
  by this plan), written to a browser's session only by that browser's
  own successful login (never resumable by an unrelated login on a shared
  browser, per docs/login-session-18.md "Step 21", also untouched). The
  path-matching fixed in step 4 above means a stash can only overlay onto
  the exact resource it was stashed from (the resource's own id is
  embedded in the compared path string), so there's no cross-project or
  cross-user leak surface.
- **Step 6** (deleting the dedicated controller): a net reduction in
  attack surface, not an increase: one fewer action that reads anything
  from params at all.

One thing specifically investigated and ruled out: whether a locale
mismatch could break the step-4 path comparison, since routes here are
locale-prefixed (`/en/...`, `/fr/...`) and login can switch `I18n.locale`
to the user's stored preference (`sessions_helper.rb:82`). Checked
`set_locale_to_best_available` (application_controller.rb:566-578):
"Locale in URL always takes precedent." Since `return_to` carries the
literal stash-time URL, including its locale segment, the post-login GET
is served under that same locale, so the edit action's own
freshly-computed comparison path uses the identical locale and matches
correctly. Not an issue.

### Functionality

The one real gap found was the step-4 matching logic (already corrected
above): comparing against `request.path`/`request.method` instead of each
form's own known submission target would have silently broken resume for
`UsersController#edit` and the permissions sub-form. With that fix, no
remaining functional hole was identified. The automation-proposals
cross-check in step 1 above confirms this plan doesn't touch that
separate, already-working feature at all.

### Estimated code-size impact

Rough, pre-implementation numbers from `wc -l` on the affected files
(actual numbers to be confirmed via `git diff --stat` once implemented):

| Change | Lines |
|---|---|
| Delete `pending_resubmissions_controller.rb` | -58 |
| Delete `pending_resubmissions/show.html.erb` | -15 |
| Delete its route (plus its comment) | -4 |
| Shrink/remove most of `pending_resubmissions_controller_test.rb` (178 lines today) | ~-150 |
| New shared overlay helper (`ApplicationController`, with YARD comments matching this codebase's style) | ~+30-35 |
| CSRF `rescue_from` plus handler | ~+12-15 |
| `redirect_after_login` simplification | ~-4 |
| `ProjectsController#edit` / `UsersController#edit` call sites | ~+8 |
| `return_to` plus token hidden fields across ~6 view partials | ~+10-12 |
| Test additions/rewrites for the new overlay behavior | ~+20-30 |

Net: roughly **120-150 fewer lines**, most of it from deleting the
dedicated controller/view and shrinking its test file, offset by a more
modest amount of small, targeted additions.
