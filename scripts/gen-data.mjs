// Generates sf data-tree sample data for the DPEG Acquisitions demo.
// Run: node scripts/gen-data.mjs   then  sf data import tree --plan data/plan.json -o DPEG-Acq
import { writeFileSync, mkdirSync } from 'node:fs';
const DIR = 'data';
mkdirSync(DIR, { recursive: true });
const file = (name, records) => writeFileSync(`${DIR}/${name}`, JSON.stringify({ records }, null, 2));
const rec = (type, referenceId, fields) => ({ attributes: { type, referenceId }, ...fields });

// --- Broker firms (Accounts) + reps (Contacts) ---
const brokers = [
  ['JLL Houston', 'Krishna', 'Rao'],
  ['CBRE', 'Mark', 'Chen'],
  ['Marcus & Millichap', 'Sofia', 'Rivera'],
  ['Newmark', 'Tom', 'Black'],
  ['Cushman & Wakefield', 'Jay', 'Patel'],
  ['Colliers', 'Ada', 'Okafor'],
];
const accounts = brokers.map(([name], i) => rec('Account', `acc_${i}`, { Name: name, Type: 'Broker Firm' }));
const contacts = brokers.map(([name, first, last], i) =>
  rec('Contact', `con_${i}`, { FirstName: first, LastName: last, AccountId: `@acc_${i}`, Title: 'Broker' }));

// --- Properties + Opportunities across all 9 stages ---
// [dealName, address, city, assetType, askingPrice, myCap, marketCap, stage, dealStatus, dealCategory, brokerIdx]
const deals = [
  ['Magnolia Crossing', '2410 FM 1488', 'Magnolia', 'Retail Strip', 31500000, 6.5, 6.5, 'LOI Signed', 'LOI Signed', 'Live', 0],
  ['Hwy 290 Retail Center', '12900 US-290', 'Cypress', 'Retail Strip', 18800000, 7.0, 6.8, 'New', 'Evaluating', 'Live', 1],
  ['Katy Mills Outparcel', '5000 Katy Mills Cir', 'Katy', 'Retail Strip', 9400000, 6.75, 6.6, 'Under Review', 'Working', 'Live', 2],
  ['Westwood Industrial Pk', '8800 Westpark Dr', 'Houston', 'Industrial', 42300000, 6.25, 6.1, 'Underwriting', 'Working', 'Live', 3],
  ['Greenway Plaza Office', '3 Greenway Plaza', 'Houston', 'Office', 55600000, 7.5, 7.2, 'LOI Submitted', 'Countered', 'Live', 4],
  ['Memorial City Office', '900 Gessner Rd', 'Houston', 'Office', 38900000, 7.25, 7.0, 'LOI Signed', 'LOI Signed', 'Live', 5],
  ['Riverside Commons', '1200 Riverside Dr', 'Austin', 'Mixed-Use', 27400000, 6.4, 6.3, 'Under Contract', 'Contract Signed', 'Live', 1],
  ['Oak Street Center', '450 Oak St', 'Dallas', 'Retail Strip', 21100000, 6.6, 6.5, 'Closed Won', 'Asset Under Management', 'Closed', 2],
  ['Texas City Storage', '2800 Palmer Hwy', 'Texas City', 'Industrial', 12750000, 7.8, 7.9, 'Dead/Pass', 'Killed', 'Dead', 3],
  ['Pearland Pad #14', '2700 Pearland Pkwy', 'Pearland', 'Land', 6800000, 6.9, 6.7, 'Portfolio Deal', 'Evaluating', 'Live', 4],
];
const properties = deals.map((d, i) =>
  rec('Property__c', `prop_${i}`, {
    Name: d[0], Address__c: d[1], City__c: d[2], State__c: 'TX', Asset_Type__c: d[3].split(' ')[0],
    Market_Cap_Rate__c: d[6], Monthly_Visits__c: 8000 + i * 1500, YoY_Growth__c: 3 + (i % 6),
    Placer_Fetch_Status__c: 'Success',
  }));
const opportunities = deals.map((d, i) => {
  const f = {
    Name: d[0], StageName: d[7], CloseDate: '2026-09-30', AccountId: `@acc_${d[10]}`, Property__c: `@prop_${i}`,
    Asset_Type__c: d[3], Asking_Price__c: d[4], Amount: d[4], My_Cap_Rate__c: d[5], Market_Cap_Rate__c: d[6],
    Deal_Status__c: d[8], Deal_Category__c: d[9], Broker_First_Seen__c: '2026-04-01',
  };
  if (d[0] === 'Pearland Pad #14') f.Is_Portfolio_Parent__c = true;
  if (d[7] === 'Dead/Pass') f.Rejection_Reason__c = 'Bad Anchor Tenant';
  return rec('Opportunity', `opp_${i}`, f);
});

// --- Leads (Lead Funnel) across the 5 statuses ---
// [dealName(address), company, status, assetType, guidancePrice, brokerDisplay, confidence, channel, daysAgo]
const leadRows = [
  ['Hwy 290 Retail Center', 'Marcus & Millichap', 'New', 'Retail', 8200000, 'Marcus & Millichap', 'HIGH', 'Email-to-Lead', 3],
  ['Katy Mills Outparcel', 'CBRE', 'Under Review', 'Retail', 3400000, 'CBRE · D.Willis', 'MEDIUM', 'Broker Portal', 5],
  ['Westwood Industrial Pk', 'JLL', 'Qualified', 'Industrial', 19600000, 'JLL', 'HIGH', 'Email-to-Lead', 8],
  ['Greenway Plaza Office', 'Newmark', 'Converted', 'Office', 42000000, 'Newmark', 'HIGH', 'Manual Entry', 13],
  ['Galveston Beach Retail', 'Unknown', 'Disqualified', 'Retail', 7100000, 'Unknown', 'LOW', 'Email-to-Lead', 23],
];
// First Seen Date is stamped at intake; the demo backdates it so the DAYS and
// BP EXPIRY (First Seen + 90) columns render realistic, self-consistent values.
const firstSeen = (daysAgo) => {
  const d = new Date('2026-06-07T09:00:00.000Z');
  d.setUTCDate(d.getUTCDate() - daysAgo);
  return d.toISOString();
};
const leads = leadRows.map((l, i) => {
  const f = {
    LastName: 'Broker', Company: l[1], Status: l[2], Asset_Type__c: l[3],
    Property_Address__c: l[0], Guidance_Price__c: l[4], Broker_First__c: l[5], Parse_Confidence__c: l[6],
    LeadSource: l[7], First_Seen_Date__c: firstSeen(l[8]),
  };
  if (l[2] === 'Disqualified') f.Disqualification_Reason__c = 'Bad Anchor Tenant';
  return rec('Lead', `lead_${i}`, f);
});

// --- Child records for Magnolia Crossing (opp_0) mirroring the prototype ---
const ndas = [rec('NDA__c', 'nda_0', {
  Opportunity__c: '@opp_0', Status__c: 'Signed', NDA_Signed__c: true, Method__c: 'DocuSign',
  Date_Sent__c: '2026-04-10', Date_Signed__c: '2026-04-11', NDA_Expiry_Date__c: '2026-10-11',
})];
const underwritings = [rec('Underwriting__c', 'uw_0', {
  Opportunity__c: '@opp_0', My_Price__c: 31500000, My_Cap_Rate__c: 6.5, Market_Cap_Rate__c: 6.5,
  Underwritten_NOI__c: 2050000, Target_Return__c: 17.4, Hold_Period__c: 5, Equity_Required__c: 9450000,
  Projected_Loan__c: 22050000,
})];
const lois = [rec('LOI__c', 'loi_0', {
  Opportunity__c: '@opp_0', LOI_Status__c: 'Signed', Offer_Price__c: 31500000, Offer_Cap_Rate__c: 6.5,
  Submitted_Date__c: '2026-04-22', Approved_Date__c: '2026-04-23', LOI_Signed__c: true, LOI_Signed_Date__c: '2026-05-02',
})];

file('accounts.json', accounts);
file('contacts.json', contacts);
file('properties.json', properties);
file('opportunities.json', opportunities);
file('leads.json', leads);
file('ndas.json', ndas);
file('underwritings.json', underwritings);
file('lois.json', lois);

const plan = [
  { sobject: 'Account', saveRefs: true, resolveRefs: false, files: ['accounts.json'] },
  { sobject: 'Contact', saveRefs: false, resolveRefs: true, files: ['contacts.json'] },
  { sobject: 'Property__c', saveRefs: true, resolveRefs: false, files: ['properties.json'] },
  { sobject: 'Opportunity', saveRefs: true, resolveRefs: true, files: ['opportunities.json'] },
  { sobject: 'Lead', saveRefs: false, resolveRefs: false, files: ['leads.json'] },
  { sobject: 'NDA__c', saveRefs: false, resolveRefs: true, files: ['ndas.json'] },
  { sobject: 'Underwriting__c', saveRefs: false, resolveRefs: true, files: ['underwritings.json'] },
  { sobject: 'LOI__c', saveRefs: false, resolveRefs: true, files: ['lois.json'] },
];
writeFileSync(`${DIR}/plan.json`, JSON.stringify(plan, null, 2));
console.log('Generated data tree:', accounts.length, 'accounts,', opportunities.length, 'opps,', leads.length, 'leads.');
