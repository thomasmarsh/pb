HA$PBExportHeader$w_misth_final_list.srw
$PBExportComments$
forward
global type w_misth_final_list from w_list
end type
end forward

global type w_misth_final_list from w_list
integer width = 3259
integer height = 2108
string title = "title"
string menuname = "m_misth_final_list"
string icon = "res\final.ico"
string is_tablename = "misth_final"
string is_order = " order by misth_final.datefinal asc "
string is_searchwin = "w_misth_final_search"
boolean ib_editwithkey = true
boolean ib_retrieve = true
boolean ib_sort = true
boolean ib_nofilter = true
event me_print_atomikes ( )
event me_print_total ( )
event me_print_custom ( )
event me_print_ypal ( )
event me_edit_plirdate ( )
end type
global w_misth_final_list w_misth_final_list

forward prototypes
public subroutine of_deleterow (ref datawindow adw, long row)
protected subroutine of_dw2struct (ref datawindow adw, long row)
protected subroutine of_struct2dw (ref datawindow adw, long row)
protected subroutine of_init_struct ()
protected subroutine of_reset_struct ()
protected subroutine of_retrieve (ref datawindow adw)
public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor)
end prototypes

event me_print_atomikes();// Εκτύπωση ατομικών καταστάσεων της επιλεγμένης μισθοδοσίας

// Παίρνουμε την επιλεγμένη μισθοδοσία
	long		ll_kodfinal
	long		ll_row
	
	ll_row = dw.getrow()
	if ll_row = 0 then return
	
	ll_kodfinal = dw.object.kodfinal[ll_row]
	
// Έλεγχος δικαιωμάτων και εκτύπωση
	if not fn_perm("misth_final_ypal", "openlist") then return
	OpenSheetWithParm(wprn_final_atomiki_misth, ll_kodfinal, w_app, 0, Original!)		

end event

event me_print_total();// Εκτύπωση συγκεντρωτικών της επιλεγμένης μισθοδοσίας

// Παίρνουμε την επιλεγμένη μισθοδοσία
	long		ll_kodfinal
	long		ll_row
	
	ll_row = dw.getrow()
	if ll_row = 0 then return
	
	ll_kodfinal = dw.object.kodfinal[ll_row]
	
// Έλεγχος δικαιωμάτων και εκτύπωση
	if not fn_perm("misth_final", "openlist") then return
	OpenSheetWithParm(wprn_final_total_misth, ll_kodfinal, w_app, 0, Original!)		

end event

event me_print_custom();// Εκτύπωση καταστάσεων χρήστη

// Παίρνουμε την επιλεγμένη μισθοδοσία
	long		ll_kodfinal
	long		ll_row
	
	ll_row = dw.getrow()
	if ll_row = 0 then return
	
	ll_kodfinal = dw.object.kodfinal[ll_row]
	
// Άνοιγμα παραθύρου για επιλογή κατάστασης
	Open(w_misth_report_select)
	if Message.DoubleParm <> 1 then return
	
// Έλεγχος δικαιωμάτων και εκτύπωση
// Το kodreport βρίσκεται στην gstring
	if not fn_perm("misth_final_ypal", "openlist") then return
	OpenSheetWithParm(wprn_report3, ll_kodfinal, w_app, 0, Original!)		

end event

event me_print_ypal();// Εκτύπωση κατάστασης υπαλλήλων με αποδοχές και κρατήσεις

// Παίρνουμε την επιλεγμένη μισθοδοσία
	long		ll_kodfinal
	long		ll_row
	
	ll_row = dw.getrow()
	if ll_row = 0 then return
	
	ll_kodfinal = dw.object.kodfinal[ll_row]
	
// Έλεγχος δικαιωμάτων και εκτύπωση
	if not fn_perm("misth_final_ypal", "openlist") then return
	OpenSheetWithParm(wprn_final_ypal_list, ll_kodfinal, w_app, 0, Original!)		

end event

event me_edit_plirdate();// Άνοιγμα του παραθύρου εισαγωγής ημ/νίας πληρωμών

// Get current kodfinal
	long		ll_row
	long		ll_kodfinal
	
	ll_row = dw.getrow()
	if ll_row = 0 then return
	ll_kodfinal = dw.object.kodfinal[ll_row]
	
// Open window
	openwithparm(w_misth_final_ypal_plirdate, ll_kodfinal)
	
// update if OK
	if Message.doubleparm <> 1 then return
	dw.setredraw(false)
	triggerevent("me_refresh")
	dw.setrow(ll_row)
	dw.scrolltorow(ll_row)
	dw.setredraw(true)
	
end event

public subroutine of_deleterow (ref datawindow adw, long row);long		ll_kodfinal

ll_kodfinal = adw.object.kodfinal[row]

delete from misth_final
where kodfinal = :ll_kodfinal and kodxrisi = :gs_kodxrisi;
fn_sqlerror()
end subroutine

protected subroutine of_dw2struct (ref datawindow adw, long row);gsc_misth_final.kodfinal = adw.object.kodfinal[row]
gsc_misth_final.kodxrisi = adw.object.kodxrisi[row]
gsc_misth_final.descfinal = adw.object.descfinal[row]
gsc_misth_final.datefinal = adw.object.datefinal[row]
gsc_misth_final.title = adw.object.title[row]
gsc_misth_final.kodkat = adw.object.kodkat[row]
gsc_misth_final.kodperiod = adw.object.misth_final_kodperiod[row]
gsc_misth_final.aa = adw.object.misth_final_aa[row]

end subroutine

protected subroutine of_struct2dw (ref datawindow adw, long row);adw.object.kodfinal[row] = gsc_misth_final.kodfinal 
adw.object.kodxrisi[row] = gsc_misth_final.kodxrisi
adw.object.descfinal[row] = gsc_misth_final.descfinal 
adw.object.datefinal[row] = gsc_misth_final.datefinal
adw.object.title[row] = gsc_misth_final.title
adw.object.kodkat[row] = gsc_misth_final.kodkat
adw.object.misth_final_aa[row] = gsc_misth_final.aa


// descperiod
	string	ls_descperiod
	select	descperiod into :ls_descperiod
	from		misth_zpperiod
	where		kodperiod = :gsc_misth_final.kodperiod
	and		kodxrisi = :gs_kodxrisi;
	fn_sqlerror()
	
	adw.object.misth_zpperiod_descperiod[row] = ls_descperiod

// desckat
	string	ls_desckat
	select desckat into :ls_desckat
	from   misth_zpkat
	where  kodkat = :gsc_misth_final.kodkat
	and    kodxrisi = :gs_kodxrisi;
	fn_sqlerror()
	
	adw.object.misth_zpkat_desckat[row] = ls_desckat
	
end subroutine

protected subroutine of_init_struct ();long		ll_aa

select max(aa) into :ll_aa from misth_final
where kodxrisi = :gs_kodxrisi;
fn_sqlerror()

if isnull(ll_aa) then 	ll_aa = 0

gsc_misth_final.kodfinal = fn_getkey("misth_final")
gsc_misth_final.aa = ll_aa + 1
gsc_misth_final.kodxrisi = gs_kodxrisi
gsc_misth_final.datefinal = today()



end subroutine

protected subroutine of_reset_struct ();gsc_misth_final_reset()
end subroutine

protected subroutine of_retrieve (ref datawindow adw);adw.retrieve(gs_kodxrisi)
end subroutine

public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor);al_rowrcolor = rgb(215,255,215)
end subroutine

on w_misth_final_list.create
call super::create
if IsValid(this.MenuID) then destroy(this.MenuID)
if this.MenuName = "m_misth_final_list" then this.MenuID = create m_misth_final_list
end on

on w_misth_final_list.destroy
call super::destroy
if IsValid(MenuID) then destroy(MenuID)
end on

event me_add;// Προσθήκη μιας νέας εγγραφής

// Έλεγχος δικαιωμάτων
	if not fn_perm(is_tablename, "addrec") then return

// Καθαρισμός της ανάλογης structure
	of_reset_struct()

// Default τιμές για νέα εγγραφή
	of_init_struct()

// Άνοιγμα της φόρμας επεξεργασίας και έλεγχος αν πατήσαμε ΟΚ ή CANCEL (override function)
// parameter = 0 -> νέα εγγραφή (for both updatable and no updateble)
	OpenWithParm(w_misth_final_form_create, 0)
	if Message.DoubleParm <> 1 then return

dw.SetRedraw(false)

// Αν πατήσαμε οκ εισάγουμε μία νέα γραμμή και μεταφέρουμε τα στοιχεία
	long	ll_row
	ll_row = dw.InsertRow(0)
	of_struct2dw(dw, ll_row)	

// Επιλέγουμε την νέα γραμμή
	//dw.SetRow(1)
	dw.SelectRow(0, false)
	dw.ScrollToRow(ll_row)
	dw.SelectRow(ll_row, true)
	dw.SetFocus()
	
dw.SetRedraw(true)
	

// update ανάλογα με την ib_update
	if ib_update then
		dw.update()
		COMMIT;
	end if
	
// check menu
	This.TriggerEvent("ie_checkmenu")

// Καλούμε την of_afterinsert()
	of_afterinsert(dw, ll_row)
	


end event

event me_edit;// Έλεγχος δικαιωμάτων
	if not fn_perm(is_tablename, "openform") then return

// Παίρνουμε την τρέχουσα γραμμή του dw
	long	ll_row
	ll_row = dw.getrow()
	if ll_row = 0 then return

// Καθαρισμός της καθολικής structure (override function)
	of_reset_struct()

// Μεταφορά των δεδομέων στην σχετική structure (override function)
	of_dw2struct(dw, ll_row)
	
// Άνοιγμα της φόρμας επεξεργασίας και έλεγχος αν πατήσαμε ΟΚ ή CANCEL (override function)
	OpenWithParm(w_misth_final_form_edit, 1)
	if Message.DoubleParm <> 1 then return
	
// Τα νέα δεδομένα από την sturcture στο dw
	of_struct2dw(dw, ll_row)
	
// update ανάλογα με την ib_update
	if ib_update then
		dw.update()
		COMMIT USING SQLCA;
	end if
	
// Καλούμε την of_afterupdate()
	of_afterupdate(dw, ll_row)

end event

event open;call super::open;// translation
	title = trn(392)
end event

type dw from w_list`dw within w_misth_final_list
integer width = 3214
string dataobject = "dw_misth_final_list"
end type

