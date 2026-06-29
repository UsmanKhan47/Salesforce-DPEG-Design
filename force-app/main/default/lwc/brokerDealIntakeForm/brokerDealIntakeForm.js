import { LightningElement, wire } from 'lwc';
import getFormMetadata from '@salesforce/apex/BrokerPortalController.getFormMetadata';
import submitDeal from '@salesforce/apex/BrokerPortalController.submitDeal';
import DPEG_LOGO from '@salesforce/resourceUrl/DPEG_Logo';

export default class BrokerDealIntakeForm extends LightningElement {
    assetTypeOptions = [];
    submitting = false;
    submitted = false;
    errorMessage = '';
    logoUrl = DPEG_LOGO;

    // form state
    firstName = '';
    lastName = '';
    brokerageFirm = '';
    email = '';
    phone = '';
    propertyAddress = '';
    assetType = '';
    website = ''; // honeypot

    @wire(getFormMetadata)
    wiredMeta({ data, error }) {
        if (data) {
            this.assetTypeOptions = data.assetTypes.map((o) => ({ label: o.label, value: o.value }));
        } else if (error) {
            this.errorMessage = 'Could not load the form. Please refresh and try again.';
        }
    }

    handleChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
    }

    handleSubmit() {
        this.errorMessage = '';
        if (!this.validate()) {
            return;
        }
        this.submitting = true;
        const input = {
            firstName: this.firstName,
            lastName: this.lastName,
            brokerageFirm: this.brokerageFirm,
            email: this.email,
            phone: this.phone,
            propertyAddress: this.propertyAddress,
            assetType: this.assetType,
            website: this.website
        };
        submitDeal({ input })
            .then((result) => {
                this.submitting = false;
                if (result && result.success) {
                    this.submitted = true;
                } else {
                    this.errorMessage = (result && result.message) || 'Something went wrong. Please try again.';
                }
            })
            .catch((error) => {
                this.submitting = false;
                this.errorMessage =
                    (error && error.body && error.body.message) || 'Something went wrong. Please try again.';
            });
    }

    validate() {
        const inputs = [...this.template.querySelectorAll('.validate')];
        let allValid = true;
        inputs.forEach((input) => {
            if (!input.reportValidity()) {
                allValid = false;
            }
        });
        return allValid;
    }

    handleReset() {
        this.submitted = false;
        this.firstName = '';
        this.lastName = '';
        this.brokerageFirm = '';
        this.email = '';
        this.phone = '';
        this.propertyAddress = '';
        this.assetType = '';
        this.website = '';
        this.errorMessage = '';
    }
}