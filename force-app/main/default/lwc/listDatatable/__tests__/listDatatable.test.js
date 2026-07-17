/**
 * SPECIAL TEMPLATE — LightningDatatable SUBCLASS
 * ----------------------------------------------
 * c-list-datatable is NOT a standalone renderable component: it has no @api
 * surface and no template of its own — it extends `lightning/datatable` purely to
 * register two custom cell types (pill, progress) via the static `customTypes`
 * config. You therefore CANNOT createElement/mount + sa11y it like a normal LWC
 * (the sfdx-lwc-jest `lightning/datatable` stub renders nothing meaningful).
 *
 * The valid unit test for a datatable subclass is a STATIC-CONFIG test: import
 * the class and assert (a) it extends the base LightningDatatable and (b) its
 * `customTypes` registers exactly the custom cell types, each with a template and
 * the correct typeAttributes. No DOM, no wire adapters, no toBeAccessible().
 *
 * Copy this shape for any other `extends LightningDatatable` bundle.
 */
import ListDatatable from 'c/listDatatable';
import LightningDatatable from 'lightning/datatable';

describe('c-list-datatable', () => {
    it('extends the base lightning/datatable', () => {
        expect(ListDatatable.prototype instanceof LightningDatatable).toBe(true);
    });

    it('registers exactly the pill and progress custom cell types', () => {
        expect(Object.keys(ListDatatable.customTypes).sort()).toEqual([
            'pill',
            'progress'
        ]);
    });

    it('configures the pill custom type with a template and its typeAttributes', () => {
        const pill = ListDatatable.customTypes.pill;
        expect(pill.template).toBeDefined();
        expect(pill.standardCellLayout).toBe(true);
        expect(pill.typeAttributes).toEqual(['wrapStyle', 'dotStyle']);
    });

    it('configures the progress custom type with a template and its typeAttributes', () => {
        const progress = ListDatatable.customTypes.progress;
        expect(progress.template).toBeDefined();
        expect(progress.standardCellLayout).toBe(true);
        expect(progress.typeAttributes).toEqual([
            'wrapStyle',
            'trackStyle',
            'barStyle',
            'numStyle',
            'text'
        ]);
    });
});
