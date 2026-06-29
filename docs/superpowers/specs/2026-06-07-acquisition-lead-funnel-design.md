# Acquisition App — Lead Funnel Page (Design)

Date: 2026-06-07
Status: Approved

## Goal
Stand up a fresh scratch org with two Lightning apps (**Acquisition** and **Disposition**),
and build the Acquisition app's default home page — **Lead Funnel** — using the
"Header and Right Sidebar" flexipage template, populated by three new LWCs split out of the
existing monolithic `leadFunnel` component.

## Org & Apps
- Fresh scratch org `DPEG-Acq-2` from `config/project-scratch-def.json`, set as default.
- Delete combined `Acquisition_Disposition.app`. Create:
  - **Acquisition** — `navType=Standard`, brand `#0B5394`, default landing = Lead Funnel AppPage.
    Tabs: Lead Funnel, Leads, Opportunities, Property, NDA, Underwriting, LOI, Reports, Dashboards.
  - **Disposition** — shell. Tabs: Offering, Transaction, Property Asset, Reports, Dashboards.

## Flexipage + Template
- `Lead_Funnel.flexipage` (masterLabel "Lead Funnel", type AppPage), replacing `Lead_Intake`.
- Template: "Header and Right Sidebar" (3 regions). Exact developer name confirmed against the org on deploy.
  - Region 1 (header, full width) -> `c:totalLeads`
  - Region 2 (main, left)        -> `c:recentLeads`
  - Region 3 (right sidebar)     -> `c:leadChannels`
- Every future flexipage reuses this same template.

## LWCs (split from monolith; then delete `leadFunnel`)
- **totalLeads** (header): title bar with **Review Queue** + **+ New Lead** buttons top-right,
  then 5 stat cards (NEW, UNDER REVIEW, QUALIFIED, CONVERTED, DISQUALIFIED) with colored top
  border, count, and description, per `total-leads.png`.
  Buttons functional: New Lead -> navigate to new Lead record; Review Queue -> filtered Leads list view.
- **recentLeads** (main/left): table per `recent-leads.png` — ID, DEAL NAME, STAGE, CHANNEL (icon),
  CONFIDENCE (HIGH/MED/LOW badge), GUIDANCE PRICE, BROKER, BP EXPIRY (shield), DAYS (pill).
  Header "Recent Leads — N records" + "Broker Protection active on all records" badge.
- **leadChannels** (right sidebar): 4 cards in a 2x2 grid — Email-to-Lead, Broker Portal,
  Manual Entry, and amber Review Queue warning card — per `lead-channels.png`.
- All three fed by `LeadFunnelController.getFunnel()` (single cacheable wire).

## Apex
- Extend `LeadFunnelController.LeadRow` with `bpExpiry` (= `First_Seen_Date__c + 90` days)
  and `bpActive` flag. Update `LeadFunnelControllerTest`. No other logic change.

## Verification
- Deploy source, run Apex tests, open Acquisition app, confirm three sections render per mocks.
