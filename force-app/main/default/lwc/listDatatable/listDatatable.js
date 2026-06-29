import LightningDatatable from 'lightning/datatable';
import pill from './pill.html';
import progress from './progress.html';

/**
 * Shared lightning-datatable subclass that adds two custom cell types so the
 * native datatable can still render soft status pills and inline progress bars.
 * Styling is inline (via typeAttributes) because a datatable subclass can't reach
 * its custom cell templates with a .css file.
 */
export default class ListDatatable extends LightningDatatable {
    static customTypes = {
        pill: {
            template: pill,
            standardCellLayout: true,
            typeAttributes: ['wrapStyle', 'dotStyle']
        },
        progress: {
            template: progress,
            standardCellLayout: true,
            typeAttributes: ['wrapStyle', 'trackStyle', 'barStyle', 'numStyle', 'text']
        }
    };
}