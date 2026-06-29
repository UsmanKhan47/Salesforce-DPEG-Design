// Populate broker Email on the 5 editable (non-converted) Lead records
List<Lead> ups = new List<Lead>{
    new Lead(Id = '00QIm000001zizpMAA', Email = 'd.willis@cbre.com'),              // CBRE
    new Lead(Id = '00QIm000001zizqMAA', Email = 'a.morgan@jll.com'),               // JLL
    new Lead(Id = '00QIm000001zizoMAA', Email = 'r.shah@marcusmillichap.com'),     // Marcus & Millichap
    new Lead(Id = '00QIm000001zizrMAA', Email = 'k.obrien@nmrk.com'),              // Newmark
    new Lead(Id = '00QIm000001zizsMAA', Email = 't.reed@gmail.com')                // Unknown
};
update ups;
System.debug('Updated broker email on ' + ups.size() + ' leads');
