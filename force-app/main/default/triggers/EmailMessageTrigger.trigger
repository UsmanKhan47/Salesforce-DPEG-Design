/**
 * Fires the EAC Thread Guard for every newly captured email. Named for the OBJECT,
 * not the feature: this org enforces one trigger per object, so any future
 * EmailMessage concern belongs in EmailMessageTriggerHandler alongside this one.
 * All logic — including why the work must be async — lives in the handler.
 */
trigger EmailMessageTrigger on EmailMessage (after insert) {
    new EmailMessageTriggerHandler().run();
}
