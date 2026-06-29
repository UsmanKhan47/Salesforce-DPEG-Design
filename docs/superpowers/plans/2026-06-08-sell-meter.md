# Sell Meter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Sell Meter landing page for the Disposition app — a portfolio table of `Property_Asset__c` records with computed Meter Score, GREEN/YELLOW/RED sell signals, and a sidebar scoring legend.

**Architecture:** Three independent LWCs (`sellMeterHeader`, `sellMeterList`, `sellMeterLegend`) mapped to regions 1/2/3 of an AppPage flexipage using `flexipage:appHomeTemplateHeaderTwoColumns`. A single `SellMeterController` Apex class provides all data. Meter Score (`impliedValue / targetPrice`) and the GREEN/YELLOW/RED classification are computed in Apex; the LWCs only render. Deploy in two waves: components first, then flexipage/tab/app.

**Tech Stack:** Salesforce CLI (`sf`), Apex, LWC, SFDX metadata XML

---

## File Map

| Action | File |
|---|---|
| Create | `force-app/main/default/objects/Property_Asset__c/fields/Argus_Signal__c.field-meta.xml` |
| Modify | `scripts/gen-metadata.mjs` (add `Argus_Signal__c` to `Property_Asset__c.fields`) |
| Modify | `force-app/main/default/permissionsets/DPEG_Acquisitions.permissionset-meta.xml` (add FLS) |
| Create | `force-app/main/default/classes/SellMeterController.cls` + `-meta.xml` |
| Create | `force-app/main/default/classes/SellMeterControllerTest.cls` + `-meta.xml` |
| Create | `force-app/main/default/lwc/sellMeterLegend/` (4 files) |
| Create | `force-app/main/default/lwc/sellMeterHeader/` (4 files) |
| Create | `force-app/main/default/lwc/sellMeterList/` (4 files) |
| Create | `force-app/main/default/flexipages/Sell_Meter.flexipage-meta.xml` |
| Create | `force-app/main/default/tabs/Sell_Meter.tab-meta.xml` |
| Modify | `force-app/main/default/applications/Disposition.app-meta.xml` (add `Sell_Meter` as first tab) |

---

## Task 1: Argus_Signal__c field, gen-metadata.mjs, and permissionset FLS

**Files:**
- Create: `force-app/main/default/objects/Property_Asset__c/fields/Argus_Signal__c.field-meta.xml`
- Modify: `scripts/gen-metadata.mjs`
- Modify: `force-app/main/default/permissionsets/DPEG_Acquisitions.permissionset-meta.xml`

- [ ] **Step 1: Create the field XML**

Create `force-app/main/default/objects/Property_Asset__c/fields/Argus_Signal__c.field-meta.xml` with this content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Argus_Signal__c</fullName>
    <label>Argus Signal</label>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Sell Now</fullName><default>false</default><label>Sell Now</label></value>
            <value><fullName>12 mo</fullName><default>false</default><label>12 mo</label></value>
            <value><fullName>Hold</fullName><default>false</default><label>Hold</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

- [ ] **Step 2: Update gen-metadata.mjs**

In `scripts/gen-metadata.mjs`, find the `Property_Asset__c` fields array (around line 170–181). Add `Argus_Signal__c` as the last entry before the closing bracket:

```js
  Property_Asset__c: {
    label: 'Property Asset', plural: 'Property Assets', nameType: 'Text', nameLabel: 'Asset Name', motif: 'Custom25: Building',
    fields: [
      { name: 'Property__c', label: 'Property', type: 'Lookup', ref: 'Property__c', relName: 'Property_Assets' },
      { name: 'Closing_Date__c', label: 'Closing Date', type: 'Date' },
      { name: 'Final_Purchase_Price__c', label: 'Final Purchase Price', type: 'Currency' },
      { name: 'Status__c', label: 'Status', type: 'Picklist', values: [{ label: 'Active', default: true }, 'Disposed'] },
      { name: 'NOI__c', label: 'NOI', type: 'Currency' },
      { name: 'Market_Cap_Rate__c', label: 'Market Cap Rate', type: 'Percent' },
      { name: 'Target_Sale_Price__c', label: 'Target Sale Price', type: 'Currency' },
      { name: 'Argus_Signal__c', label: 'Argus Signal', type: 'Picklist', values: ['Sell Now', '12 mo', 'Hold'] },
    ],
  },
```

- [ ] **Step 3: Add FLS to the permissionset**

In `force-app/main/default/permissionsets/DPEG_Acquisitions.permissionset-meta.xml`, find the block for `Property_Asset__c.Target_Sale_Price__c` and add the `Argus_Signal__c` entry immediately after it:

```xml
    <fieldPermissions>
        <field>Property_Asset__c.Argus_Signal__c</field><readable>true</readable><editable>true</editable>
    </fieldPermissions>
```

---

## Task 2: SellMeterController + SellMeterControllerTest (TDD)

**Files:**
- Create: `force-app/main/default/classes/SellMeterControllerTest.cls`
- Create: `force-app/main/default/classes/SellMeterControllerTest.cls-meta.xml`
- Create: `force-app/main/default/classes/SellMeterController.cls`
- Create: `force-app/main/default/classes/SellMeterController.cls-meta.xml`

- [ ] **Step 1: Create the test class**

Create `force-app/main/default/classes/SellMeterControllerTest.cls`:

```apex
@isTest
private class SellMeterControllerTest {
    @testSetup
    static void setup() {
        // Three properties (asset type comes from Property__r.Asset_Type__c).
        Property__c pA = new Property__c(Name = 'Prop A', Asset_Type__c = 'Retail');
        Property__c pB = new Property__c(Name = 'Prop B', Asset_Type__c = 'Multifamily');
        Property__c pC = new Property__c(Name = 'Prop C', Asset_Type__c = 'Storage');
        insert new List<Property__c>{ pA, pB, pC };

        // Implied Value = NOI / (Cap / 100).  All three use NOI=1000000, Cap=5.0 → Implied=20000000.
        // Asset A: Target=18000000 → Score=1.111 → GREEN  (>= 1.05)
        // Asset B: Target=20500000 → Score=0.976 → YELLOW (>= 0.95, < 1.05)
        // Asset C: Target=22000000 → Score=0.909 → RED    (< 0.95)
        // Asset D: null NOI         → null score  (null guard)
        insert new List<Property_Asset__c>{
            new Property_Asset__c(Name = 'Test Asset A', Property__c = pA.Id,
                NOI__c = 1000000, Market_Cap_Rate__c = 5.0, Target_Sale_Price__c = 18000000,
                Argus_Signal__c = 'Sell Now'),
            new Property_Asset__c(Name = 'Test Asset B', Property__c = pB.Id,
                NOI__c = 1000000, Market_Cap_Rate__c = 5.0, Target_Sale_Price__c = 20500000,
                Argus_Signal__c = '12 mo'),
            new Property_Asset__c(Name = 'Test Asset C', Property__c = pC.Id,
                NOI__c = 1000000, Market_Cap_Rate__c = 5.0, Target_Sale_Price__c = 22000000,
                Argus_Signal__c = 'Hold'),
            new Property_Asset__c(Name = 'Test Asset D', Property__c = pA.Id,
                NOI__c = null, Market_Cap_Rate__c = null, Target_Sale_Price__c = null)
        };
    }

    @isTest
    static void testThresholds() {
        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        Test.stopTest();

        System.assertEquals(4, rows.size(), 'Four assets expected');

        // Results are ORDER BY Name so A/B/C/D is deterministic.
        SellMeterController.PropertyRow a = rows[0];
        System.assertEquals('GREEN', a.sellMeter, 'Asset A: score 1.11 should be GREEN');
        System.assertNotEquals(null, a.impliedValue, 'Implied value should be computed for A');
        System.assertEquals('Sell Now', a.argusSignal, 'Argus signal should pass through');
        System.assertEquals('Retail', a.assetType, 'Asset type cross-object lookup should resolve');

        SellMeterController.PropertyRow b = rows[1];
        System.assertEquals('YELLOW', b.sellMeter, 'Asset B: score 0.976 should be YELLOW');

        SellMeterController.PropertyRow c = rows[2];
        System.assertEquals('RED', c.sellMeter, 'Asset C: score 0.909 should be RED');

        SellMeterController.PropertyRow d = rows[3];
        System.assertEquals(null, d.sellMeter, 'Asset D: null NOI should leave sellMeter null');
        System.assertEquals(null, d.impliedValue, 'Asset D: null NOI should leave impliedValue null');
    }
}
```

- [ ] **Step 2: Create the test class meta**

Create `force-app/main/default/classes/SellMeterControllerTest.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 3: Create the controller class**

Create `force-app/main/default/classes/SellMeterController.cls`:

```apex
public with sharing class SellMeterController {

    public class PropertyRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String assetType;
        @AuraEnabled public Decimal noi;
        @AuraEnabled public Decimal mktCapRate;
        @AuraEnabled public Decimal impliedValue;
        @AuraEnabled public Decimal targetPrice;
        @AuraEnabled public Decimal meterScore;
        @AuraEnabled public String sellMeter;
        @AuraEnabled public String argusSignal;
    }

    @AuraEnabled(cacheable=true)
    public static List<PropertyRow> getPortfolio() {
        List<Property_Asset__c> assets = [
            SELECT Id, Name, Property__r.Asset_Type__c,
                   NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Argus_Signal__c
            FROM Property_Asset__c
            ORDER BY Name
        ];
        List<PropertyRow> rows = new List<PropertyRow>();
        for (Property_Asset__c a : assets) {
            PropertyRow r = new PropertyRow();
            r.id = a.Id;
            r.name = a.Name;
            r.assetType = a.Property__r != null ? a.Property__r.Asset_Type__c : null;
            r.noi = a.NOI__c;
            r.mktCapRate = a.Market_Cap_Rate__c;
            r.targetPrice = a.Target_Sale_Price__c;
            r.argusSignal = a.Argus_Signal__c;
            if (a.NOI__c != null && a.Market_Cap_Rate__c != null && a.Market_Cap_Rate__c != 0) {
                r.impliedValue = a.NOI__c / (a.Market_Cap_Rate__c / 100);
                if (a.Target_Sale_Price__c != null && a.Target_Sale_Price__c != 0) {
                    r.meterScore = r.impliedValue / a.Target_Sale_Price__c;
                    r.sellMeter = r.meterScore >= 1.05 ? 'GREEN'
                        : (r.meterScore >= 0.95 ? 'YELLOW' : 'RED');
                }
            }
            rows.add(r);
        }
        return rows;
    }
}
```

- [ ] **Step 4: Create the controller class meta**

Create `force-app/main/default/classes/SellMeterController.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

---

## Task 3: sellMeterLegend LWC (static sidebar)

**Files:**
- Create: `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.html`
- Create: `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.js`
- Create: `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.css`
- Create: `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.js-meta.xml`

- [ ] **Step 1: Create the HTML**

Create `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.html`:

```html
<template>
    <div class="legend">
        <div class="legend__title">Sell Meter Scoring</div>

        <div class="band band--green">
            <div class="band__threshold">&#x2265; 1.05</div>
            <div class="band__label">GREEN</div>
            <div class="band__desc">Auto-email Ali + Nick + Nikil · Executive Dashboard flagged · Junior prompted for BOV outreach</div>
        </div>

        <div class="band band--yellow">
            <div class="band__threshold">&#x2265; 0.95</div>
            <div class="band__label">YELLOW</div>
            <div class="band__desc">Approaching watchlist · weekly monitoring · no BOV yet</div>
        </div>

        <div class="band band--red">
            <div class="band__threshold">&lt; 0.95</div>
            <div class="band__label">RED</div>
            <div class="band__desc">No automated action · asset remains under management</div>
        </div>
    </div>
</template>
```

- [ ] **Step 2: Create the CSS**

Create `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.css`:

```css
:host {
    display: block;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    color: #181818;
}
.legend__title {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.06em;
    color: #8a96a3;
    text-transform: uppercase;
    margin-bottom: 12px;
}
.band {
    border-radius: 8px;
    padding: 14px 16px;
    margin-bottom: 10px;
    border: 1px solid #e3e6eb;
    border-left-width: 4px;
}
.band--green {
    background: #f0faf4;
    border-left-color: #1B7A4B;
}
.band--yellow {
    background: #fffbf0;
    border-left-color: #B45309;
}
.band--red {
    background: #fff5f5;
    border-left-color: #B91C1C;
}
.band__threshold {
    font-size: 12px;
    font-weight: 700;
    color: #5a6b7b;
}
.band__label {
    font-size: 14px;
    font-weight: 700;
    margin: 4px 0 6px;
}
.band--green .band__label { color: #1B7A4B; }
.band--yellow .band__label { color: #B45309; }
.band--red .band__label { color: #B91C1C; }
.band__desc {
    font-size: 12px;
    color: #5a6b7b;
    line-height: 1.5;
}
```

- [ ] **Step 3: Create the JS**

Create `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.js`:

```js
import { LightningElement } from 'lwc';
export default class SellMeterLegend extends LightningElement {}
```

- [ ] **Step 4: Create the meta XML**

Create `force-app/main/default/lwc/sellMeterLegend/sellMeterLegend.js-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Sell Meter Legend</masterLabel>
    <description>Disposition Sell Meter sidebar — static GREEN/YELLOW/RED scoring bands.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

---

## Task 4: sellMeterHeader LWC (region1 header bar)

**Files:**
- Create: `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.html`
- Create: `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.js`
- Create: `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.css`
- Create: `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.js-meta.xml`

- [ ] **Step 1: Create the HTML**

Create `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.html`:

```html
<template>
    <div class="smh">
        <div class="smh__title">Portfolio &middot; Sell Meter &mdash; All Properties</div>
        <div class="smh__meta">
            <span>{assetCount} assets</span>
            <span class="smh__sep">&middot;</span>
            <span>CoStar last sync: Sun Jun 1, 2026</span>
            <span class="smh__sep">&middot;</span>
            <span>Yardi: 2h ago</span>
        </div>
    </div>
</template>
```

- [ ] **Step 2: Create the JS**

Create `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.js`:

```js
import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';

export default class SellMeterHeader extends LightningElement {
    _rows;

    @wire(getPortfolio)
    wired({ data }) {
        if (data) {
            this._rows = data;
        }
    }

    get assetCount() {
        return this._rows ? this._rows.length : 0;
    }
}
```

- [ ] **Step 3: Create the CSS**

Create `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.css`:

```css
:host {
    display: block;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}
.smh {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 20px;
    background: #fff;
    border: 1px solid #e3e6eb;
    border-radius: 10px;
}
.smh__title {
    font-size: 15px;
    font-weight: 700;
    color: #181818;
}
.smh__meta {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12.5px;
    color: #8a96a3;
}
.smh__sep {
    color: #c5cdd4;
}
```

- [ ] **Step 4: Create the meta XML**

Create `force-app/main/default/lwc/sellMeterHeader/sellMeterHeader.js-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Sell Meter Header</masterLabel>
    <description>Disposition Sell Meter — portfolio title bar with asset count and sync timestamps.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

---

## Task 5: sellMeterList LWC (region2 main table)

**Files:**
- Create: `force-app/main/default/lwc/sellMeterList/sellMeterList.html`
- Create: `force-app/main/default/lwc/sellMeterList/sellMeterList.js`
- Create: `force-app/main/default/lwc/sellMeterList/sellMeterList.css`
- Create: `force-app/main/default/lwc/sellMeterList/sellMeterList.js-meta.xml`

- [ ] **Step 1: Create the HTML**

Create `force-app/main/default/lwc/sellMeterList/sellMeterList.html`:

```html
<template>
    <div class="card">
        <div class="tbl__wrap">
            <table class="tbl">
                <thead>
                    <tr>
                        <th>PROPERTY</th>
                        <th>TYPE</th>
                        <th class="num">NOI (YARDI)</th>
                        <th class="num">MKT CAP</th>
                        <th class="num">IMPLIED VALUE</th>
                        <th class="num">TARGET PRICE</th>
                        <th class="num">METER SCORE</th>
                        <th>SELL METER</th>
                        <th>ARGUS SIGNAL</th>
                        <th>ACTION</th>
                    </tr>
                </thead>
                <tbody>
                    <template for:each={rows} for:item="r">
                        <tr key={r.id}>
                            <td class="strong">{r.name}</td>
                            <td class="muted">{r.assetType}</td>
                            <td class="num">{r.noiLabel}</td>
                            <td class="num">{r.capRateLabel}</td>
                            <td class="num">{r.impliedLabel}</td>
                            <td class="num">{r.targetLabel}</td>
                            <td class="num strong">{r.meterScoreLabel}</td>
                            <td><span class="pill" style={r.meterStyle}>{r.sellMeter}</span></td>
                            <td>{r.argusSignal}</td>
                            <td>
                                <template if:true={r.isGreen}>
                                    <button class="btn btn--initiate" data-id={r.id} onclick={handleInitiate}>Initiate &#x2192;</button>
                                </template>
                                <template if:true={r.isYellow}>
                                    <button class="btn btn--monitor">Monitor</button>
                                </template>
                                <template if:true={r.isRed}>
                                    <span class="hold-text">Hold</span>
                                </template>
                            </td>
                        </tr>
                    </template>
                </tbody>
            </table>
        </div>
    </div>
</template>
```

- [ ] **Step 2: Create the JS**

Create `force-app/main/default/lwc/sellMeterList/sellMeterList.js`:

```js
import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';

const METER_COLORS = {
    GREEN:  '#1B7A4B',
    YELLOW: '#B45309',
    RED:    '#B91C1C'
};

export default class SellMeterList extends LightningElement {
    _data;

    @wire(getPortfolio)
    wired({ data }) {
        if (data) {
            this._data = data;
        }
    }

    get rows() {
        if (!this._data) return [];
        return this._data.map(r => {
            const meter = r.sellMeter || 'RED';
            const color = METER_COLORS[meter] || METER_COLORS.RED;
            return {
                id:             r.id,
                name:           r.name,
                assetType:      r.assetType || '—',
                noiLabel:       this._fmtM(r.noi),
                capRateLabel:   r.mktCapRate != null ? r.mktCapRate.toFixed(1) + '%' : '—',
                impliedLabel:   this._fmtM(r.impliedValue),
                targetLabel:    this._fmtM(r.targetPrice),
                meterScoreLabel: r.meterScore != null ? r.meterScore.toFixed(2) + '×' : '—',
                sellMeter:      meter,
                meterStyle:     `background:${color};color:#fff`,
                argusSignal:    r.argusSignal || '—',
                isGreen:        meter === 'GREEN',
                isYellow:       meter === 'YELLOW',
                isRed:          meter === 'RED'
            };
        });
    }

    handleInitiate(event) {
        // Flow wiring added in a future phase once screenshots are provided.
        const id = event.currentTarget.dataset.id;
        console.log('Initiate disposition for asset:', id);
    }

    _fmtM(val) {
        if (val == null) return '—';
        return '$' + (val / 1_000_000).toFixed(1) + 'M';
    }
}
```

- [ ] **Step 3: Create the CSS**

Create `force-app/main/default/lwc/sellMeterList/sellMeterList.css`:

```css
:host {
    display: block;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    color: #181818;
}
.card {
    background: #fff;
    border: 1px solid #e3e6eb;
    border-radius: 10px;
    overflow: hidden;
}
.tbl__wrap {
    overflow-x: auto;
}
.tbl {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
}
.tbl th {
    text-align: left;
    font-size: 10.5px;
    letter-spacing: 0.05em;
    color: #8a96a3;
    font-weight: 700;
    padding: 10px 16px;
    border-bottom: 1px solid #eef1f4;
    white-space: nowrap;
}
.tbl td {
    padding: 12px 16px;
    border-bottom: 1px solid #f3f5f7;
    white-space: nowrap;
}
.tbl tbody tr:last-child td {
    border-bottom: none;
}
.tbl tbody tr:hover {
    background: #f7fafd;
}
.num {
    text-align: right;
}
.strong {
    font-weight: 600;
}
.muted {
    color: #8a96a3;
}
.pill {
    display: inline-block;
    padding: 3px 12px;
    border-radius: 12px;
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.03em;
}
.btn {
    border: none;
    border-radius: 6px;
    cursor: pointer;
    font-size: 12.5px;
    font-weight: 600;
    padding: 5px 14px;
    font-family: inherit;
}
.btn--initiate {
    background: #1565C0;
    color: #fff;
}
.btn--initiate:hover {
    background: #1251A3;
}
.btn--monitor {
    background: #fff;
    color: #5a6b7b;
    border: 1.5px solid #c5cdd4;
}
.btn--monitor:hover {
    background: #f1f4f7;
}
.hold-text {
    color: #8a96a3;
    font-size: 12.5px;
}
```

- [ ] **Step 4: Create the meta XML**

Create `force-app/main/default/lwc/sellMeterList/sellMeterList.js-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Sell Meter List</masterLabel>
    <description>Disposition Sell Meter — portfolio table with meter score, sell signal, and action buttons.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

---

## Task 6: Deploy Wave 1 (field + Apex + LWCs + permissionset)

**IMPORTANT:** Deploy components before the flexipage. If both go in one deploy, a flexipage failure rolls back the LWC deployment too — leaving the org without the components the flexipage references. The next flexipage-only deploy then fails with a misleading "design time component" error that actually means the LWC isn't in the org.

- [ ] **Step 1: Deploy Wave 1**

Run from the repo root:

```
sf project deploy start -d force-app/main/default/objects/Property_Asset__c/fields/Argus_Signal__c.field-meta.xml -d force-app/main/default/classes/SellMeterController.cls -d force-app/main/default/classes/SellMeterController.cls-meta.xml -d force-app/main/default/classes/SellMeterControllerTest.cls -d force-app/main/default/classes/SellMeterControllerTest.cls-meta.xml -d force-app/main/default/lwc/sellMeterHeader -d force-app/main/default/lwc/sellMeterList -d force-app/main/default/lwc/sellMeterLegend -d force-app/main/default/permissionsets/DPEG_Acquisitions.permissionset-meta.xml
```

Expected: `Deploy Succeeded` with no failures.

- [ ] **Step 2: Run Apex tests in the org**

```
sf apex run test --class-names SellMeterControllerTest --result-format human --wait 5
```

Expected output (after "Test Results"):
```
SellMeterControllerTest.testThresholds  Pass
```

If the test fails, fix the controller logic or test setup data and redeploy only the changed class before continuing.

- [ ] **Step 3: Seed sample data**

If the org has no `Property_Asset__c` records yet, create 5 records manually (or via data import) matching the design screenshot so the page renders with real data:

| Asset Name | Property (Asset Type) | NOI | Cap Rate | Target Price | Argus Signal |
|---|---|---|---|---|---|
| Sienna Town Center | (Retail) | 1800000 | 6.5 | 26900000 | Sell Now |
| Westheimer C-Stores ×9 | (C-Store) | 2900000 | 6.8 | 40000000 | Sell Now |
| Heights Apartments | (Multifamily) | 4200000 | 5.8 | 75000000 | 12 mo |
| Texas City Self-Storage | (Storage) | 980000 | 7.1 | 16000000 | Hold |
| Beltway Office Park | (Office) | 2000000 | 9.2 | 24000000 | Hold |

Note: "C-Store" and "Office" may need to be added as picklist values to `Property__c.Asset_Type__c` if they are not already present (the current generator `ASSET` array has `['Retail', 'Land', 'Industrial', 'Office', 'Multifamily', 'Mixed-Use']` — add C-Store if needed).

---

## Task 7: Sell_Meter flexipage, tab, and Disposition app update

**Files:**
- Create: `force-app/main/default/flexipages/Sell_Meter.flexipage-meta.xml`
- Create: `force-app/main/default/tabs/Sell_Meter.tab-meta.xml`
- Modify: `force-app/main/default/applications/Disposition.app-meta.xml`

- [ ] **Step 1: Create the flexipage**

Create `force-app/main/default/flexipages/Sell_Meter.flexipage-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <name>region1</name>
        <type>Region</type>
        <itemInstances>
            <componentInstance>
                <componentName>c:sellMeterHeader</componentName>
                <identifier>sellMeterHeaderComponent</identifier>
            </componentInstance>
        </itemInstances>
    </flexiPageRegions>
    <flexiPageRegions>
        <name>region2</name>
        <type>Region</type>
        <itemInstances>
            <componentInstance>
                <componentName>c:sellMeterList</componentName>
                <identifier>sellMeterListComponent</identifier>
            </componentInstance>
        </itemInstances>
    </flexiPageRegions>
    <flexiPageRegions>
        <name>region3</name>
        <type>Region</type>
        <itemInstances>
            <componentInstance>
                <componentName>c:sellMeterLegend</componentName>
                <identifier>sellMeterLegendComponent</identifier>
            </componentInstance>
        </itemInstances>
    </flexiPageRegions>
    <masterLabel>Sell Meter</masterLabel>
    <template>
        <name>flexipage:appHomeTemplateHeaderTwoColumns</name>
    </template>
    <type>AppPage</type>
</FlexiPage>
```

- [ ] **Step 2: Create the tab**

Create `force-app/main/default/tabs/Sell_Meter.tab-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPage>Sell_Meter</flexiPage>
    <label>Sell Meter</label>
    <motif>Custom51: Money</motif>
</CustomTab>
```

- [ ] **Step 3: Update the Disposition app**

Edit `force-app/main/default/applications/Disposition.app-meta.xml`. Replace the `<tabs>` block so `Sell_Meter` is first:

```xml
    <tabs>Sell_Meter</tabs>
    <tabs>Offering__c</tabs>
    <tabs>Transaction__c</tabs>
    <tabs>Property_Asset__c</tabs>
    <tabs>standard-report</tabs>
    <tabs>standard-Dashboard</tabs>
```

The full file should look like:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomApplication xmlns="http://soap.sforce.com/2006/04/metadata">
    <brand>
        <headerColor>#1B7A4B</headerColor>
        <shouldOverrideOrgTheme>true</shouldOverrideOrgTheme>
    </brand>
    <description>DPEG real estate dispositions — offerings, marketing, and transactions.</description>
    <formFactors>Large</formFactors>
    <isNavAutoTempTabsDisabled>false</isNavAutoTempTabsDisabled>
    <isNavPersonalizationDisabled>false</isNavPersonalizationDisabled>
    <isNavTabPersistenceDisabled>false</isNavTabPersistenceDisabled>
    <isOmniPinnedViewEnabled>false</isOmniPinnedViewEnabled>
    <label>Disposition</label>
    <navType>Standard</navType>
    <tabs>Sell_Meter</tabs>
    <tabs>Offering__c</tabs>
    <tabs>Transaction__c</tabs>
    <tabs>Property_Asset__c</tabs>
    <tabs>standard-report</tabs>
    <tabs>standard-Dashboard</tabs>
    <uiType>Lightning</uiType>
</CustomApplication>
```

---

## Task 8: Deploy Wave 2 (flexipage + tab + app) and verify

- [ ] **Step 1: Deploy Wave 2**

```
sf project deploy start -d force-app/main/default/flexipages/Sell_Meter.flexipage-meta.xml -d force-app/main/default/tabs/Sell_Meter.tab-meta.xml -d force-app/main/default/applications/Disposition.app-meta.xml
```

Expected: `Deploy Succeeded` with no failures.

- [ ] **Step 2: Open the Disposition app and verify**

In the org, switch to the **Disposition** app. It should open on the **Sell Meter** tab (first nav item). Verify:

1. Header bar shows "Portfolio · Sell Meter — All Properties" and the asset count
2. Table rows show all seeded `Property_Asset__c` records with formatted NOI, Cap, Implied Value, Target, and Meter Score
3. GREEN rows show a filled green pill and a blue "Initiate →" button
4. YELLOW rows show an amber pill and an outline "Monitor" button
5. RED rows show a red pill and plain "Hold" text
6. Sidebar shows three scoring bands (green/yellow/red) with correct threshold labels and descriptions

If the page is blank or shows an error, check the browser console for the LWC wire error — the most common cause is the Apex class not deployed in Wave 1.
