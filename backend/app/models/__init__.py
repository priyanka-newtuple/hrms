"""
Import every model module here so Alembic's autogenerate and Base.metadata
see the full schema regardless of which module happens to import `Base` first.
"""

from app.models.allocation import Allocation
from app.models.asset import Asset, AssetAssignment
from app.models.audit import AuditLog
from app.models.document import EmployeeDocument
from app.models.employee import Employee
from app.models.helpdesk import HelpdeskCategory, HelpdeskTicket
from app.models.hr_content import EmployeeReferral, JobDescription, JobOpening, LearningEvent, OrganizationPolicy
from app.models.invitation import EmployeeInvitation
from app.models.notification import NotificationOutbox
from app.models.onboarding import OnboardingRecord, OnboardingTask
from app.models.onboarding_template import OnboardingTemplate, OnboardingTemplateStep
from app.models.performance import PerformanceCycle, PerformanceGoal, PerformanceReview, ProjectFeedback
from app.models.project import Customer, Project, ProjectApprovalRequest
from app.models.reference_data import Department, Designation, ProjectRole
from app.models.role import Role, RoleFeaturePermission, RolePermissionKey
from app.models.timesheet import Holiday, LeaveRequest, Timesheet, TimesheetApproval
from app.models.user import User

__all__ = [
    "Allocation",
    "Asset",
    "AssetAssignment",
    "AuditLog",
    "Employee",
    "EmployeeDocument",
    "EmployeeInvitation",
    "HelpdeskCategory",
    "HelpdeskTicket",
    "OrganizationPolicy",
    "LearningEvent",
    "JobDescription",
    "JobOpening",
    "EmployeeReferral",
    "NotificationOutbox",
    "OnboardingRecord",
    "OnboardingTask",
    "OnboardingTemplate",
    "OnboardingTemplateStep",
    "PerformanceCycle",
    "PerformanceGoal",
    "PerformanceReview",
    "ProjectFeedback",
    "Customer",
    "Project",
    "ProjectApprovalRequest",
    "Department",
    "Designation",
    "ProjectRole",
    "Role",
    "RoleFeaturePermission",
    "RolePermissionKey",
    "Timesheet",
    "TimesheetApproval",
    "Holiday",
    "LeaveRequest",
    "User",
]
