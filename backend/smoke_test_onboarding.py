"""
End-to-end smoke test of the onboarding flow engine, run inside the backend
container against the live API. Walks the whole pipeline as the real roles:
HR starts onboarding -> Office Admin & Finance complete their steps ->
invitation auto-sends -> new hire fills the wizard + uploads docs ->
HR verifies -> asset assignment & allocation auto-complete their steps ->
record completes. Deleted after the run.
"""

import asyncio
from datetime import date

import httpx

BASE = "http://localhost:8000/api/v1"

checks: list[tuple[str, bool]] = []


def check(name: str, ok: bool, extra: str = "") -> None:
    checks.append((name, ok))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{f'  [{extra}]' if extra else ''}")


async def login(email: str) -> httpx.AsyncClient:
    client = httpx.AsyncClient(base_url=BASE, timeout=30)
    r = await client.post("/auth/dev-login", json={"email": email})
    r.raise_for_status()
    return client


def task_by_seq(record: dict, seq: int) -> dict:
    return next(t for t in record["tasks"] if t["seq"] == seq)


async def main() -> None:
    hr = await login("kavya.menon@newtuple.com")  # HR - Full
    admin = await login("suresh.nair@newtuple.com")  # Office Admin
    finance = await login("neha.gupta@newtuple.com")  # Finance
    hr_basic = await login("rohit.sharma@newtuple.com")  # HR - Basic
    dm = await login("vikram.iyer@newtuple.com")  # Delivery Manager

    # ---- pick an employee with no open onboarding
    employees = (await hr.get("/employees", params={"page_size": 100})).json()["items"]
    onboarding_pages = (
        await hr.get("/onboarding", params={"workflow_type": "onboarding", "page_size": 200})
    ).json()["items"]
    busy_ids = {r["employee_id"] for r in onboarding_pages if r["status"] != "completed"}
    candidate = next(
        e
        for e in employees
        if e["id"] not in busy_ids
        and e["department"] == "Engineering"
        and e["employment_status"] == "active"
    )
    print(f"\nCandidate new hire: {candidate['full_name']} ({candidate['work_email']})")

    # ---- HR starts onboarding
    r = await hr.post(
        "/onboarding/start",
        json={"employee_id": candidate["id"], "workflow_type": "onboarding"},
    )
    check("start onboarding", r.status_code == 200, str(r.status_code))
    record = r.json()
    rid = record["id"]
    check("8 template tasks stamped", len(record["tasks"]) == 8, str(len(record["tasks"])))
    check(
        "steps 1+2 ready in parallel",
        task_by_seq(record, 1)["status"] == "ready" and task_by_seq(record, 2)["status"] == "ready",
    )
    check(
        "later steps pending",
        all(task_by_seq(record, s)["status"] == "pending" for s in (3, 4, 5, 7, 8)),
    )
    check(
        "assignees resolved",
        all(t["assignee_name"] for t in record["tasks"]),
        ", ".join(f"{t['seq']}:{t['assignee_name']}" for t in record["tasks"]),
    )

    # duplicate start must conflict
    r = await hr.post(
        "/onboarding/start",
        json={"employee_id": candidate["id"], "workflow_type": "onboarding"},
    )
    check("duplicate start rejected (409)", r.status_code == 409, str(r.status_code))

    # ---- Finance completes Razorpay step (as assignee, without EDIT permission)
    t2 = task_by_seq(record, 2)
    r = await finance.post(
        f"/onboarding/{rid}/tasks/{t2['id']}/complete",
        json={"note": "Razorpay contact created", "payroll_reference": "cont_SMOKE123"},
    )
    check("assignee (Finance) completes own step", r.status_code == 200, str(r.status_code))

    # ---- Office Admin completes Newtuple ID -> invitation should auto-run
    record = (await hr.get(f"/onboarding/{rid}")).json()
    t1 = task_by_seq(record, 1)
    r = await admin.post(
        f"/onboarding/{rid}/tasks/{t1['id']}/complete",
        json={"note": "Workspace account live"},
    )
    check("Office Admin completes Newtuple ID", r.status_code == 200, str(r.status_code))
    record = r.json()
    check("invitation step auto-completed", task_by_seq(record, 3)["status"] == "done")
    check(
        "profile + documents steps now ready",
        task_by_seq(record, 4)["status"] == "ready"
        and task_by_seq(record, 5)["status"] == "ready",
    )
    check("asset step ready (dep on step 1)", task_by_seq(record, 6)["status"] == "ready")

    # random employee must NOT be able to touch someone else's step
    outsider = await login("sanjay.bhat@newtuple.com")
    if candidate["work_email"] == "sanjay.bhat@newtuple.com":
        outsider = await login("meera.pillai@newtuple.com")
    t7 = task_by_seq(record, 7)
    r = await outsider.post(f"/onboarding/{rid}/tasks/{t7['id']}/complete", json={})
    check("outsider blocked from completing (403)", r.status_code == 403, str(r.status_code))

    # ---- Office Admin's queue shows the asset step
    r = await admin.get("/onboarding/my-actions")
    actions = r.json()
    check(
        "asset step in Office Admin queue",
        any(a["task"]["step_key"] == "asset_allocation" and a["record_id"] == rid for a in actions),
        f"{len(actions)} actions",
    )

    # ---- new hire wizard
    hire = await login(candidate["work_email"])
    me = (await hire.get("/onboarding/me")).json()
    check("new hire sees own onboarding (/me)", me is not None and me["id"] == rid)
    check("invitation attached", bool(me.get("invitation")), str(me.get("invitation", {}).get("status")))

    r = await hire.post(
        "/onboarding/me/profile",
        json={
            "phone": "+91-9000000001",
            "personal_email": "smoke.hire@gmail.com",
            "address": "12 Test Lane, Bengaluru",
            "bank_account_number": "50210001112223",
            "bank_ifsc": "HDFC0009999",
        },
    )
    me = r.json()
    check("wizard submit completes profile step", task_by_seq(me, 4)["status"] == "done")
    check(
        "HR orientation + PM allocation now ready",
        task_by_seq(me, 7)["status"] == "ready" and task_by_seq(me, 8)["status"] == "ready",
    )

    # ---- documents: upload required four, HR verifies
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 100
    for doc_type in ("id_proof", "pan", "education_certificate", "signed_offer_letter"):
        r = await hire.post(
            f"/onboarding/employees/{candidate['id']}/documents",
            data={"doc_type": doc_type},
            files={"file": (f"{doc_type}.png", png, "image/png")},
        )
        assert r.status_code == 200, f"upload {doc_type}: {r.status_code} {r.text}"
    check("4 required documents uploaded", True)

    # reject one, expect re-upload flow
    detail = (await hr.get(f"/onboarding/{rid}")).json()
    pan = next(d for d in detail["documents"] if d["doc_type"] == "pan")
    r = await hr.post(
        f"/onboarding/documents/{pan['id']}/review",
        json={"status": "rejected", "note": "Photo is blurry"},
    )
    check("HR can reject a document", r.status_code == 200, str(r.status_code))
    r = await hire.post(
        f"/onboarding/employees/{candidate['id']}/documents",
        data={"doc_type": "pan"},
        files={"file": ("pan_v2.png", png, "image/png")},
    )
    check("re-upload after rejection", r.status_code == 200, str(r.status_code))

    detail = (await hr.get(f"/onboarding/{rid}")).json()
    for doc in detail["documents"]:
        if doc["status"] == "submitted":
            r = await hr.post(
                f"/onboarding/documents/{doc['id']}/review",
                json={"status": "verified"},
            )
            assert r.status_code == 200, f"verify: {r.text}"
    detail = (await hr.get(f"/onboarding/{rid}")).json()
    check(
        "documents step auto-completed after verification",
        task_by_seq(detail, 5)["status"] == "done",
    )

    # ---- asset assignment auto-completes step 6
    assets = (await admin.get("/assets", params={"page_size": 200})).json()["items"]
    free = next(a for a in assets if a["status"] == "in_stock")
    r = await admin.post(
        f"/assets/{free['id']}/assign",
        json={"employee_id": candidate["id"], "assigned_date": str(date.today())},
    )
    check("asset assigned via Assets module", r.status_code == 201, str(r.status_code))
    detail = (await hr.get(f"/onboarding/{rid}")).json()
    t6 = task_by_seq(detail, 6)
    check(
        "asset step auto-completed + linked",
        t6["status"] == "done" and t6["linked_entity_type"] == "asset_assignment",
    )

    # ---- HR orientation (HR - Basic is the assignee)
    t7 = task_by_seq(detail, 7)
    r = await hr_basic.post(
        f"/onboarding/{rid}/tasks/{t7['id']}/complete",
        json={"note": "Orientation held"},
    )
    check("HR-Basic completes orientation", r.status_code == 200, str(r.status_code))

    # ---- allocation auto-completes step 8 (choose a project the hire isn't on)
    allocs = (
        await dm.get("/allocations", params={"employee_id": candidate["id"], "page_size": 200})
    ).json()["items"]
    used_projects = {a["project_id"] for a in allocs}
    projects = (await dm.get("/projects", params={"page_size": 200})).json()["items"]
    target = next(
        p for p in projects if p["id"] not in used_projects and p["status"] == "active"
    )
    r = await dm.post(
        "/allocations",
        json={
            "employee_id": candidate["id"],
            "project_id": target["id"],
            "allocation_percent": 10,
            "role_on_project": "Developer",
            "start_date": str(date.today()),
        },
    )
    check("allocation created via Allocations module", r.status_code == 201, str(r.status_code))

    final = (await hr.get(f"/onboarding/{rid}")).json()
    t8 = task_by_seq(final, 8)
    check(
        "PM allocation step auto-completed + linked",
        t8["status"] == "done" and t8["linked_entity_type"] == "allocation",
    )
    check("record completed", final["status"] == "completed")
    check(
        "progress 8/8",
        final["progress_done"] == 8 and final["progress_total"] == 8,
        f"{final['progress_done']}/{final['progress_total']}",
    )

    # ---- outbox: emails were queued along the way
    from app.database import AsyncSessionLocal
    from sqlalchemy import func, select

    from app.models.notification import NotificationOutbox

    async with AsyncSessionLocal() as db:
        counts = dict(
            (await db.execute(
                select(NotificationOutbox.status, func.count()).group_by(NotificationOutbox.status)
            )).all()
        )
    total_emails = sum(counts.values())
    check("handoff emails queued", total_emails >= 6, f"outbox: {counts}")

    for client in (hr, admin, finance, hr_basic, dm, hire, outsider):
        await client.aclose()

    failed = [n for n, ok in checks if not ok]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed")
    if failed:
        raise SystemExit("FAILED: " + "; ".join(failed))


asyncio.run(main())
