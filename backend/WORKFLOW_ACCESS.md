# My Work and workflow access

## User journey

The default signed-in landing page is `/my-work`. It contains paginated To do,
Waiting, and Completed views, Action/Approval filters, and a ready-work count in
the sidebar. Counts refresh every 30 seconds and when the browser regains focus.

Only HR - Basic, HR - Full, and Super Admin have the seeded onboarding/offboarding
module grants. Other roles participate through named task assignments. Their
independent access to Assets, Projects, and other modules is unchanged.

Assigned actions open `/my-work/tasks/:id`. The page contains the employee's
name, department and joining date, the single task, its deadline, and the relevant
form. Assets and allocations create their real module records; they cannot be
marked done manually. The task fixes the target employee server-side. Project
allocation continues to enforce the actor's allocation permission and project
scope. A task assignment can authorize an asset handover without granting access
to the inventory module itself.

Employees retain `/welcome` for their own profile/documents. Its checklist is
limited to their assigned steps. My Onboarding appears in navigation while their
onboarding is open. HR retains full workflow progress and can reassign unfinished
manual, asset, and allocation tasks with an audit reason. Self-service and system
steps cannot be reassigned. Former assignees lose task access immediately.

## Approvals

Submitted employee documents appear in the shared **HR review queue** in My Work
and open `/my-work/documents/:id`. Every eligible HR process owner sees the review;
the first valid decision wins. The employee sees submissions under Waiting.
Approve verifies the document. Request changes records a rejection reason and
uses the existing employee re-upload notification. Only the newest upload of a
document type can be reviewed. Reviewers cannot approve their own document or a
file they uploaded on another employee's behalf.

This release covers onboarding actions, assigned legacy offboarding tasks,
document approvals, and weekly timesheet approvals. Expense approval
aggregation, configurable approval chains, automatic overdue
reminders/escalations, and pooled-task claiming are not included. Document
approvals intentionally use a shared HR queue; action tasks use a named assignee.

## Enforcement

- `/onboarding` list, detail and start are process-owner operations.
- `/work` reads never grant access to parent workflow records, invitations,
  unrelated tasks, documents, or sensitive employee fields.
- All task mutation endpoints recheck assignment and current task state.
- Workflow row locks serialize task transitions and dependency handoffs.
- Asset row locks prevent two simultaneous handovers of the same stock item.
- Document row locks prevent competing decisions; workflow locks coordinate
  related document submissions and handoffs.
- Legacy task-completion endpoints return only the changed task, not the whole
  workflow. Clients should invalidate/refetch authorized views after completion.
- Frontend query caches are cleared on session refresh/logout to avoid showing
  another persona's cached work.

## Deployment and verification

Run `alembic upgrade head` in the backend. Revision `c6d8a1209f34` changes the
existing five participant-role grants, so already-seeded databases do not need
to be reseeded. HR and Super Admin retain their grants. Customized roles should
be reviewed separately. Refresh existing browser sessions to reload navigation
permissions.

The permission seed now intentionally overrides the original workbook for
onboarding/offboarding ownership. Keep this distinction when updating grants.

`tests/test_work_inbox.py` covers role/module isolation, safe task responses,
assignment changes, action/state checks, real asset assignment, project scope,
review/re-upload/self-approval rules, concurrency, pagination, and anonymous
access. Run tests only against a disposable PostgreSQL database: the existing
test fixture drops and recreates its schema.


## Project approval workflow

Migration `d7a120fb9e62` adds project requests and explicit Projects Submit grants
for Project Manager and Delivery Manager. Existing projects remain approved.
Refresh sessions after migration to load updated grants.

PM and DM create Planned drafts, then explicitly submit from My Work. Pending
requests appear in the submitter's Waiting tab and the project approver's
Approvals filter under To do. Super Admin can create an approved Planned project directly;
this exception is recorded in request history and the audit log. Submitted
requests cannot be approved by their author, including Super Admin amendments.
A separate authorized approver must handle those requests.

Request changes and rejection require a note. The author can withdraw pending
requests for editing; returned requests can be edited and resubmitted. Rejection
is terminal for that request. Every submission stores a versioned snapshot.
Decisions lock the project and require the current version, preventing stale or
simultaneous decisions from overwriting one another.

Unapproved projects cannot be activated, allocated, or used for timesheets.
Drafts and review details are restricted to the project owners and authorized
approvers within their record scope. Material changes to approved projects
create amendments; approved live values remain intact until review succeeds.
Proposed dates cannot exclude committed allocations. Commercial fields remain
subject to existing data permissions throughout the request and its history.

Submission and decision notifications are queued through the existing outbox.
Delivery depends on the configured notification worker and email provider.
`tests/test_project_approvals.py` covers creation permissions, workflow isolation,
submission, decisions, resubmission, withdrawal, concurrent review, staged
amendments, and operational restrictions.

## Workforce reference values

Departments, designations, and project roles are stored in the `departments`,
`designations`, and `project_roles` tables. Active rows populate employee and
allocation dropdowns, and write services reject values outside those tables.
Migrations `e8b4c2107a93` and `f9c5d3218ba4` seed the initial lists, preserve
existing organization-specific values, and normalize legacy whitespace and
capitalization. Foreign keys prevent referenced values from being deleted.

## Timesheets, leave, and holidays

Migration `a0d6e4329cb5` adds dated timesheet entries, task details, company
holidays, and leave requests. Migration `b1e7f5430dc6` grants HR Full managers
the approval action for their direct reports. Existing aggregate timesheets
remain valid with a null work date; new weekly entries are unique per employee,
project, and day.

Employees enter time in a seven-day grid containing only approved operational
projects allocated to them for the selected date. They can save drafts and
submit the entire week. Submitted rows are locked until the employee's current
reporting manager, or Super Admin, approves or rejects the week. Managers see
only direct-report submissions. My Submissions shows the employee's submitted
weeks, total hours, current status, pending approver, reviewer, and decision
comment. The monthly view combines daily time, leave, and company holidays.

Employees can request annual, sick, casual, unpaid, or other leave. The request
is routed to their reporting manager captured at submission. An approved leave
day blocks time entry and removes any overlapping draft time. A leave request
cannot be approved while submitted or approved time exists in its date range.

HR - Basic, HR - Full, and Super Admin can maintain the shared holiday calendar.
All employees can view active holidays. Active holiday dates are disabled in the
weekly grid and rejected again by the service during save and submit so the rule
does not depend on the browser.

`tests/test_timesheet_calendar.py` covers holiday permissions and visibility,
holiday entry blocking, task details, weekly submission and reporting-manager
approval, monthly data, leave routing, leave approval, and leave entry blocking.

## Performance management

Migration `c2f8a6541ed7` adds the Performance Management feature grant, review
cycles, weighted goals, employee and manager reviews, calibration, publication,
acknowledgement, and allocation-based project feedback.

HR Full and Super Admin can create cycle drafts. A cycle owner submits the
configuration and a different Super Admin approves it before employee reviews
are created. Employees can access only their own review and must submit goals
whose weights total exactly 100%. The reporting manager approves or returns
those goals, then receives the self-review and completes the manager assessment.

When self-review is submitted, project-feedback requests are created for project
managers whose committed allocations overlap the cycle. A project manager sees
only the assigned feedback request, not the employee's complete appraisal.
The reporting manager's manager, HR Full, or Super Admin can calibrate a manager
rating. HR Full or Super Admin publishes the calibrated result, after which the
employee can see the final rating and acknowledge it. Preliminary manager and
calibration ratings are withheld from the employee until publication.

Performance actions and approvals appear in My Work and link to the PMS
workspace. Access is relationship-based: project ownership grants feedback
access, while `reports_to_id` controls goal and appraisal approval. Compensation
data is not part of PMS and remains governed by its existing sensitive-data
permissions.

`tests/test_performance_management.py` covers cycle ownership and approval,
100%-weighted goals, reporting-manager isolation, self-review confidentiality,
allocation-based project feedback, second-level calibration, HR publication,
employee acknowledgement, My Work integration, and HR Basic restrictions.
