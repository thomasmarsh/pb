HA$PBExportHeader$w_misth_final_form_create.srw
$PBExportComments$
forward
global type w_misth_final_form_create from w_form
end type
type dw_fylo from datawindow within w_misth_final_form_create
end type
type st_1 from statictext within w_misth_final_form_create
end type
type gb_1 from groupbox within w_misth_final_form_create
end type
end forward

global type w_misth_final_form_create from w_form
integer width = 2857
integer height = 1692
string title = "title"
string icon = "res\final.ico"
boolean ib_update = true
string is_tablename = "misth_final"
dw_fylo dw_fylo
st_1 st_1
gb_1 gb_1
end type
global w_misth_final_form_create w_misth_final_form_create

type variables
long		il_kodfinal
end variables

forward prototypes
public function boolean of_check4required (ref datawindow adw, long row)
public subroutine of_dw2struct (ref datawindow adw, long row)
public subroutine of_struct2dw (ref datawindow adw, long row)
protected subroutine of_storekey ()
protected subroutine of_retrieve ()
public subroutine of_setmasks ()
public function boolean if_double_ypal ()
public function long if_getfyla (ref string as_fyla[])
public subroutine if_create_misth ()
public function long if_fylo_rows ()
public subroutine if_insert_epidom (long al_kodypal, ref datastore ads_epidom)
public subroutine if_insert_krat (long al_kodypal, ref datastore ads_krat)
end prototypes

public function boolean of_check4required (ref datawindow adw, long row);string		lstring	
long		llong	
long		ll_count
date		ldate

// aa
	llong	= adw.object.aa[row]
	if isnull(llong) then
		Messagebox(gs_app_name, trn(157))
		adw.setfocus()
		adw.setcolumn("aa")
		return false
	end if
		
// kodperiod
	lstring = adw.object.kodperiod[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, trn(182))
		adw.setfocus()
		adw.setcolumn("kodperiod")
		return false
	end if

// kodkat
	lstring = adw.object.kodkat[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, trn(171))
		adw.setfocus()
		adw.setcolumn("kodkat")
		return false
	end if

// datefinal
	ldate	= adw.object.datefinal[row]
	if isnull(ldate) then
		Messagebox(gs_app_name, trn(170))
		adw.setfocus()
		adw.setcolumn("datefinal")
		return false
	end if	
	
// descfinal
	lstring = adw.object.descfinal[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, trn(177))
		adw.setfocus()
		adw.setcolumn("descfinal")
		return false
	end if
	
// Έλεγχος αν επιλέξαμε τουλάχιστον ένα φύλλο υπολογισμού
	if if_fylo_rows() = 0 then
		Messagebox(gs_app_name, trn(205))
		dw_fylo.setfocus()
		return false
	end if

// Έλεγχος για διπλοεγγραφές υπαλλήλων
// (υπάλληλοι που είναι επιλεγμένοι σε περισσότερα του ένα φύλλα υπολογισμού
	if if_double_ypal() then return false
	
// everything ok
	return true
end function

public subroutine of_dw2struct (ref datawindow adw, long row);gsc_misth_final.kodfinal = adw.object.kodfinal[row]
gsc_misth_final.kodxrisi = adw.object.kodxrisi[row]
gsc_misth_final.descfinal = adw.object.descfinal[row]
gsc_misth_final.datefinal = adw.object.datefinal[row]
gsc_misth_final.title = adw.object.title[row]
gsc_misth_final.kodkat = adw.object.kodkat[row]
gsc_misth_final.kodperiod = adw.object.kodperiod[row]

end subroutine

public subroutine of_struct2dw (ref datawindow adw, long row);adw.object.kodfinal[row] = gsc_misth_final.kodfinal 
adw.object.kodxrisi[row] = gsc_misth_final.kodxrisi
adw.object.descfinal[row] = gsc_misth_final.descfinal 
adw.object.datefinal[row] = gsc_misth_final.datefinal
adw.object.title[row] = gsc_misth_final.title
adw.object.kodkat[row] = gsc_misth_final.kodkat
adw.object.kodperiod[row] = gsc_misth_final.kodperiod
adw.object.aa[row] = gsc_misth_final.aa

end subroutine

protected subroutine of_storekey ();il_kodfinal = gsc_misth_final.kodfinal
end subroutine

protected subroutine of_retrieve ();dw_main.retrieve(string(il_kodfinal), gs_kodxrisi)

end subroutine

public subroutine of_setmasks ();fn_seteditmask(dw_main, "datefinal", fn_param_maskdate_e())
fn_seteditmask(dw_main, "plirdate", fn_param_maskdate_e())
end subroutine

public function boolean if_double_ypal ();// Έλεγχος αν υπάρχουν υπάλληλοι σε περισσότερα του ενός 
// από τα επιλεγμένα φύλλα υπολογισμού

// Παίρνουμε επιλεγμένα φύλλα υπολογισμού στον πίνακα ls_fylo[]
// Η μεταβλητή n περιέχει των αριθμό των επιλεγμένων φύλλων
	string		ls_fylo[]
	long		ll_rows, i, n
	
	ll_rows = dw_fylo.rowcount()
	n = 0
	
	for i = 1 to ll_rows
		if dw_fylo.object.checked[i] = 1 then
			n = n + 1
			ls_fylo[n] = dw_fylo.object.kodfylo[i]
		end if
	next
	
// Σχηματίζουμε την where clause από τα επιλεγμένα φύλα
// Προσθέτουμε και τη χρήση 
	string		ls_where
	
	for i = 1 to n
		ls_where = ls_where + " OR kodfylo = '" + ls_fylo[i] + "' "
	next
	
	ls_where = right(ls_where, len(ls_where) - 4)		// αφαίρεση του πρώτου " OR "
	
	ls_where = " WHERE kodxrisi = '" + gs_kodxrisi + "' AND (" + ls_where + ") "	// τελική WHERE
	
// Μετράμε τις εγγραφές του misth_fylo_ypal για τα επιλεγμένα φύλλα
// και τις συγκρίνουμε με τις αντίστοιχες distinct
// Αν δεν είναι ίσες, σημαίνει ότι υπάρχουν διπλοεγγραφές
	string		ls_sql, ls_sql_distinct
	long		ll_count, ll_count_distinct
	long		ll_kodypal
	
	ls_sql = "SELECT count(kodypal) from misth_fylo_ypal" + ls_where
	ls_sql_distinct = "SELECT distinct kodypal from misth_fylo_ypal" + ls_where

	DECLARE cur DYNAMIC CURSOR FOR SQLSA;
	PREPARE SQLSA FROM :ls_sql USING SQLCA;
	OPEN DYNAMIC cur;
	
	if SQLCA.SQLCode < 0 then
		MessageBox("Database error", "Unable to open cursor 'cur' into 'if_double_ypal() - " + SQLCA.SQLErrText)
		return true
	end if
	
	FETCH cur into :ll_count;
	CLOSE cur;

	ll_count_distinct = 0	// counter
	DECLARE cur_distinct DYNAMIC CURSOR FOR SQLSA;
	PREPARE SQLSA FROM :ls_sql_distinct USING SQLCA;
	OPEN DYNAMIC cur_distinct;
	
	if SQLCA.SQLCode < 0 then
		MessageBox("Database error", "Unable to open cursor 'cur_distinct' into 'if_double_ypal() - " + SQLCA.SQLErrText)
		return true
	end if
	
	do while SQLCA.SQLCode = 0
		FETCH cur_distinct into :ll_kodypal;
		if SQLCA.SQLCode = 0 then
			ll_count_distinct = ll_count_distinct + 1
		end if
	loop
	
	CLOSE cur_distinct;

	if ll_count = ll_count_distinct then
		return false		// no double ypal
	else
		MessageBox(gs_app_name, trn(284))
		return true		// double ypal
	end if

end function

public function long if_getfyla (ref string as_fyla[]);// Επιστροφή των επιλεγμένω φύλλων στην as_fyla

	long	ll_checkedrows, ll_rows, i
	ll_checkedrows = 0
	
	ll_rows = dw_fylo.rowcount()
	
	for i = 1 to ll_rows
		if dw_fylo.object.checked[i] = 1 then 
			ll_checkedrows = ll_checkedrows + 1
			as_fyla[ll_checkedrows] = dw_fylo.object.kodfylo[i]
		end if
	next
	
	return ll_checkedrows
			 
end function

public subroutine if_create_misth ();// Δημιουργία μισθοδοσίας για τα επιλεγμένα φύλα

// Διαγραφή προηγούμενων υπαλλήλων της επιλεγμένης μισθοδοσίας
	long		ll_kodfinal
	
	ll_kodfinal = dw_main.object.kodfinal[1]
	
	delete from misth_final_ypal
	where kodfinal = :ll_kodfinal and kodxrisi = :gs_kodxrisi;
	fn_sqlerror()
	commit;

// Παίρνουμε τα επιλεγμένα φύλα
	string		ls_fyla[]
	long			ll_nfyla
	
	ll_nfyla = if_getfyla(ls_fyla)

// Για κάθε φύλλο
	int				i, j
	datastore	lds_ypal, lds_epidom, lds_krat
	string		ls_kodfylo
	long			ll_nypal
	long			ll_kodypal
		
	for i = 1 to ll_nfyla
		
		// Δημιουργία datastore με τους υπαλλήλους του τρέχοντος φύλλου
			lds_ypal = fn_createds("dw_misth_fylo_ypal_list")
			ll_nypal = lds_ypal.retrieve(ls_fyla[i], gs_kodxrisi)
	
			for j = 1 to ll_nypal	// Για κάθε υπάλληλο
				
				ll_kodypal = lds_ypal.object.misth_fylo_ypal_kodypal[j]
				lds_epidom = fn_parseall_epidom(ls_fyla[i], ll_kodypal)
				lds_krat = fn_parseall_krat(ls_fyla[i], ll_kodypal)
				
				// Εισαγωγή του υπαλλήλου στον misth_final_ypal
					insert into misth_final_ypal(
						kodfinal,
						kodypal,
						kodxrisi)
					values(
						:ll_kodfinal,
						:ll_kodypal,
						:gs_kodxrisi);
					fn_sqlerror()
					commit;
				
				// Εισαγωγή επιδομάτων και κρατήσεων
					 if_insert_epidom(ll_kodypal, lds_epidom)		// misth_final_ypal_epidom
					 if_insert_krat(ll_kodypal, lds_krat)				// misth_final_ypal_krat
				
			next	// επόμενος υπάλληλος
	
		// clean-up και continue
			destroy lds_ypal
			destroy lds_epidom
			destroy lds_krat
	
	next		// Επόμενο φύλλο

// Επιστροφή
end subroutine

public function long if_fylo_rows ();// Επιστροφή του αριθμού των επιλεγμένων φύλων υπολογισμού

	long	ll_checkedrows, ll_rows, i
	ll_checkedrows = 0
	
	ll_rows = dw_fylo.rowcount()
	
	for i = 1 to ll_rows
		if dw_fylo.object.checked[i] = 1 then ll_checkedrows = ll_checkedrows + 1
	next
	
	return ll_checkedrows
			
end function

public subroutine if_insert_epidom (long al_kodypal, ref datastore ads_epidom);// Εισαγωγή των επιδομάτων στον misth_final_epidom

// Παίρνουμε τον αριθμό της μισθοδοσίας
	long		ll_kodfinal
	
	ll_kodfinal = dw_main.object.kodfinal[1]

// Εισάγουμε ένα-ένα τα επιδόματα
// Ο υπάλληλος έχει ήδη εισαχθεί στον misth_final_ypal
	long		i, ll_rows
	string	ls_kodepidom
	double	ld_poso
	string	ls_notes
	
	ll_rows = ads_epidom.rowcount()
	
	for i = 1 to ll_rows
		
		ls_kodepidom = ads_epidom.object.kodvar[i]
		ld_poso = ads_epidom.object.poso[i]
		ls_notes = ads_epidom.object.notes[i]
		
		insert into misth_final_ypal_epidom(
				kodfinal,
				kodypal,
				kodepidom,
				kodxrisi,
				poso,
				aa,
				notes)
		values (
				:ll_kodfinal,
				:al_kodypal,
				:ls_kodepidom,
				:gs_kodxrisi,
				:ld_poso,
				:i,
				:ls_notes);
		
		fn_sqlerror()
		
	next	// Επόμενο επίδομα
end subroutine

public subroutine if_insert_krat (long al_kodypal, ref datastore ads_krat);// Εισαγωγή των κρατήσεων στον misth_final_krat

// Παίρνουμε τον αριθμό της μισθοδοσίας
	long		ll_kodfinal
	
	ll_kodfinal = dw_main.object.kodfinal[1]
	
// Εισάγουμε μία-μία τις κρατήσεις
// Ο υπάλληλος έχει ήδη εισαχθεί στον misth_final_ypal
	long		i, ll_rows
	string	ls_kodkrat
	double	ld_poso
	string	ls_notes
	
	ll_rows = ads_krat.rowcount()
	
	for i = 1 to ll_rows
		
		ls_kodkrat = ads_krat.object.kodvar[i]
		ld_poso = ads_krat.object.poso[i]
		ls_notes = ads_krat.object.notes[i]
		
		insert into misth_final_ypal_krat(
				kodfinal,
				kodypal,
				kodkrat,
				kodxrisi,
				poso,
				aa,
				notes)
		values (
				:ll_kodfinal,
				:al_kodypal,
				:ls_kodkrat,
				:gs_kodxrisi,
				:ld_poso,
				:i,
				:ls_notes);
		
		fn_sqlerror()
		
	next	// Επόμενη κράτηση
	
end subroutine

on w_misth_final_form_create.create
int iCurrent
call super::create
this.dw_fylo=create dw_fylo
this.st_1=create st_1
this.gb_1=create gb_1
iCurrent=UpperBound(this.Control)
this.Control[iCurrent+1]=this.dw_fylo
this.Control[iCurrent+2]=this.st_1
this.Control[iCurrent+3]=this.gb_1
end on

on w_misth_final_form_create.destroy
call super::destroy
destroy(this.dw_fylo)
destroy(this.st_1)
destroy(this.gb_1)
end on

event open;call super::open;fn_retrievechild(dw_main, "kodkat", gs_kodxrisi)
fn_retrievechild(dw_main, "kodperiod", gs_kodxrisi)

dw_fylo.settransobject(sqlca)
dw_fylo.retrieve(gs_kodxrisi)

// translate
	title = trn(598)
	cb_ok.text = trn(208)
	st_1.text = trn(326) + ":"
end event

type cb_cancel from w_form`cb_cancel within w_misth_final_form_create
integer x = 2473
integer y = 1472
integer width = 334
end type

type cb_ok from w_form`cb_ok within w_misth_final_form_create
integer x = 2473
integer y = 1324
integer width = 334
string text = "Create"
end type

event cb_ok::clicked;// Δημιουργία μισθοδοσίας

	of_AcceptText()

// Check of_ok
	if not of_ok() then return

// Αν λείπουν υποχρεωτικά πεδία δεν προχωράμε
	if not of_check4required(dw_main, 1) then return

// Τα στοιχεία πίσω στην structure
	of_dw2struct(dw_main, 1)
	
	open(w_pleasewait)
	
// Αν είναι update ανανεώνουμε το dw_main
	if ib_update then
		of_update()
		COMMIT;
	end if

// Δημιουργία μισθοδοσίας
	if_create_misth()
	
	close(w_pleasewait)

// Επιστροφή με ΟΚ		
	CloseWithReturn(GetParent(), 1)


end event

type dw_main from w_form`dw_main within w_misth_final_form_create
integer x = 37
integer y = 64
integer width = 2747
integer height = 356
string dataobject = "dw_misth_final_form"
end type

type dw_fylo from datawindow within w_misth_final_form_create
integer x = 23
integer y = 556
integer width = 2400
integer height = 1036
integer taborder = 20
boolean bringtotop = true
string title = "none"
string dataobject = "pick_misth_fylo_xrisi_check"
boolean vscrollbar = true
boolean livescroll = true
borderstyle borderstyle = stylelowered!
end type

type st_1 from statictext within w_misth_final_form_create
integer x = 32
integer y = 472
integer width = 951
integer height = 56
boolean bringtotop = true
integer textsize = -9
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial Greek"
long textcolor = 128
long backcolor = 67108864
boolean focusrectangle = false
end type

type gb_1 from groupbox within w_misth_final_form_create
integer x = 23
integer y = 4
integer width = 2784
integer height = 440
integer taborder = 10
integer textsize = -9
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial Greek"
long textcolor = 33554432
long backcolor = 67108864
end type

