HA$PBExportHeader$uo_misth_ypal_yvar_grid.sru
$PBExportComments$
forward
global type uo_misth_ypal_yvar_grid from u_grid
end type
type pb_expr from picturebutton within uo_misth_ypal_yvar_grid
end type
type pb_get from picturebutton within uo_misth_ypal_yvar_grid
end type
end forward

global type uo_misth_ypal_yvar_grid from u_grid
integer width = 2542
integer height = 936
string is_tablename = "misth_ypal_epidom"
pb_expr pb_expr
pb_get pb_get
end type
global uo_misth_ypal_yvar_grid uo_misth_ypal_yvar_grid

type variables
w_misth_ypal_form		iw_parent
end variables

forward prototypes
public subroutine of_postinitrow (ref datawindow adw, long row)
public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor)
public function boolean of_check4required (ref datawindow adw, long row)
public function boolean if_kodyvar_exists (string as_kodyvar)
end prototypes

public subroutine of_postinitrow (ref datawindow adw, long row);adw.object.kodypal[row] = iw_parent.idw_main.object.kodypal[1]
adw.object.kodxrisi[row] = gs_kodxrisi
adw.object.aa[row ] = fn_maxindw(adw, "aa") + 1
end subroutine

public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor);al_rowrcolor = rgb(204,255,204)
end subroutine

public function boolean of_check4required (ref datawindow adw, long row);
string		lstring	
long		ll_found	
date		ldate
time		ltime

// kodyvar
	lstring = adw.object.kodyvar[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, trn(204))
		adw.setfocus()
		adw.setcolumn("kodyvar")
		return false
	end if
	
	// Έλεγχος αν ο κωδικός υπάρχει
		ll_found = adw.find("kodyvar = '" + lstring + "'", 1, adw.rowcount())
		if ll_found = row then ll_found = adw.find("kodyvar = '" + lstring + "'", ll_found + 1, adw.rowcount())
		if ll_found > 0 and ll_found <> row then
			MessageBox(gs_app_name, trn(129))
			adw.setfocus()
			adw.Setcolumn("kodyvar")
			return false
		end if		

// everything ok
	return true
end function

public function boolean if_kodyvar_exists (string as_kodyvar);// Έλεγχος αν η μεταβλητή as_kodyvar υπάρχει στο dw_main

	long		ll_found
	long		row

	ll_found = dw.find("kodyvar = '" + as_kodyvar + "'", 1, dw.rowcount())
	if ll_found = row then ll_found = dw.find("kodyvar = '" + as_kodyvar + "'", ll_found + 1, dw.rowcount())
	
	if ll_found > 0 and ll_found <> row then
		return true		// Υπάρχει
	else
		return false		// Δεν υπάρχει
	end if		


end function

on uo_misth_ypal_yvar_grid.create
int iCurrent
call super::create
this.pb_expr=create pb_expr
this.pb_get=create pb_get
iCurrent=UpperBound(this.Control)
this.Control[iCurrent+1]=this.pb_expr
this.Control[iCurrent+2]=this.pb_get
end on

on uo_misth_ypal_yvar_grid.destroy
call super::destroy
destroy(this.pb_expr)
destroy(this.pb_get)
end on

event ie_checkbuttons;long	ll_nrows, ll_row

// Σύνολο εγγραφών και τρέχουσα εγγραφή
	ll_nrows = dw.rowcount()
	ll_row = dw.getrow()
	
// Επαναφέρουμε όλα σε ενεργό κατάσταση και απενεργοποιούμε ανάλογα
	pb_delete.enabled = true
	pb_selectrow.enabled = true
	pb_selectall.enabled = true
	pb_expr.enabled = true
		
	pb_first.enabled = true
	pb_previous.enabled = true
	pb_next.enabled = true
	pb_last.enabled = true
	pb_new.enabled = true
	

// Αν δεν υπάρχουν εγγραφές παρά μόνο η νέα
	if ll_nrows = 1 then
		pb_delete.enabled = false
		pb_selectrow.enabled = false
		pb_selectall.enabled = false
		pb_first.enabled = false
		pb_previous.enabled = false
		pb_next.enabled = false
		pb_last.enabled = false
		pb_new.enabled = false
		pb_expr.enabled = false
		return
	end if
		
// Είμαστε στην τελευταία εγγραφή (νέα) αλλά υπάρχουν και άλλες
	if ll_row = ll_nrows and ll_nrows > 1 then
		pb_selectrow.enabled = false
		pb_new.enabled = false
		pb_next.enabled = false
		pb_delete.enabled = false
		return
	end if	
	
// Είμαστε στην πρώτη εγγραφή και υπάρχουν και άλλες
	if ll_row = 1 and ll_nrows > 1 then
		pb_first.enabled = false
		pb_previous.enabled = false
		
		// Αν είναι και η μοναδική εγγραφή (προτελευταία)
		if ll_row = ll_nrows - 1 then
			pb_last.enabled = false
		end if
		
		return
	end if
	
// Αν είμαστε στην προτελευταία (πριν την νέα)
	if ll_row = ll_nrows - 1 then
		pb_last.enabled = false
		return
	end if
	
end event

event constructor;call super::constructor;// Translation
	pb_expr.powertiptext = trn(303)
	pb_get.powertiptext = trn(440)
	
end event

type pb_selectall from u_grid`pb_selectall within uo_misth_ypal_yvar_grid
integer x = 2267
end type

type pb_selectrow from u_grid`pb_selectrow within uo_misth_ypal_yvar_grid
integer x = 2153
end type

type pb_new from u_grid`pb_new within uo_misth_ypal_yvar_grid
integer x = 1989
end type

type pb_last from u_grid`pb_last within uo_misth_ypal_yvar_grid
integer x = 1865
end type

type pb_next from u_grid`pb_next within uo_misth_ypal_yvar_grid
integer x = 1751
end type

type pb_previous from u_grid`pb_previous within uo_misth_ypal_yvar_grid
integer x = 1637
end type

type pb_first from u_grid`pb_first within uo_misth_ypal_yvar_grid
integer x = 1522
end type

type pb_delete from u_grid`pb_delete within uo_misth_ypal_yvar_grid
integer x = 2432
end type

type dw from u_grid`dw within uo_misth_ypal_yvar_grid
integer width = 2537
integer height = 820
string dataobject = "dw_misth_ypal_yvar_list"
end type

event dw::itemchanged;call super::itemchanged;choose case dwo.name
		
	case "kodyvar"
		string		ls_expr
		
		select expr into :ls_expr
		from  misth_zpyvar
		where kodyvar = :data and kodxrisi = :gs_kodxrisi;
		fn_sqlerror()
		
		this.object.expr[row] = ls_expr

end choose
end event

type pb_expr from picturebutton within uo_misth_ypal_yvar_grid
integer width = 101
integer height = 88
integer taborder = 50
boolean bringtotop = true
integer textsize = -10
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial"
string picturename = "Custom082!"
alignment htextalign = left!
boolean map3dcolors = true
end type

event clicked;dw.AcceptText()

// Παίρνουμε την τρέχουσα εγγραφή
	long	ll_row
	ll_row = dw.getrow()
	if ll_row = 0 then return

// Παίρνουμε τον τρέχον τύπο
	string		ls_expr 
	ls_expr = dw.object.expr[ll_row]

// Φόρτωμα σταθερών
	datastore		lds_stath
	lds_stath = fn_createds_zpstath()
	
// Φόρτωμα μεταβλητών υπαλλήλων που έχουν καταχωρηθεί στο dw
	datastore		lds_yvar
	lds_yvar = fn_createds_zpyvar(dw)
	
// Μεταφορά σε structure και άνοιγμα w_expr
	s_expr	lsc_expr
	
	if lds_stath.rowcount() > 0 then
		lsc_expr.stath = lds_stath
	end if

	if lds_yvar.rowcount() > 0 then
		lsc_expr.yvar = lds_yvar
	end if
	
	lsc_expr.expr = ls_expr

	
// Άνοιγμα w_expr
	integer	li_ret
	openwithparm(w_expr, lsc_expr)
	li_ret = message.doubleparm
	if li_ret <> 1 then return
	dw.object.expr[ll_row] = gstring
	
// cleanup
	destroy lds_stath
	destroy lds_yvar
			
		

end event

type pb_get from picturebutton within uo_misth_ypal_yvar_grid
integer x = 114
integer width = 101
integer height = 88
integer taborder = 50
boolean bringtotop = true
integer textsize = -10
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial"
string picturename = "CheckIn!"
alignment htextalign = left!
boolean map3dcolors = true
end type

event clicked;// Μεταφορά μεταβλητών από άλλον υπάλληλο

// Παίρνουμε τον κωδικό του τρέχοντος υπαλλήλου
	long		ll_kodypal
	
	ll_kodypal = iw_parent.il_kodypal

// Επιλογή υπαλλήλου
	long		ll_kodypal_from
	
	Open(w_misth_ypal_get)
	ll_kodypal_from = Message.DoubleParm
	
	if ll_kodypal = 0 or isnull(ll_kodypal) then return
	
// Δημιουργία datastore για τις μεταβλητές του επιλεγμένου υπαλλήλου
	datastore	ds
	string			ls_sql
	long			ll_rows
	
	ls_sql = 	"select kodyvar, expr, aa " + &
			    	"from misth_ypal_yvar " + &
				"where kodypal = " + string(ll_kodypal_from) +  & 
				" and kodxrisi = '" + gs_kodxrisi + "'" + &
				" order by aa"
				
	ds = fn_createds_fromsql(ls_sql)
	ll_rows = ds.retrieve()

// Μεταφορά στον τρέχον υπάλληλο
	long 		i
	string		ls_kodyvar, ls_expr
	integer	li_aa
	long		row
	
	row = dw.rowcount()		// Η τελευταία κενή εγγραφή
	dw.setrow(row)
	
	for i = 1 to ll_rows
		
		ls_kodyvar = ds.object.kodyvar[i]
		ls_expr = ds.object.expr[i]
		li_aa = ds.object.aa[i]
		
		// Αν η μεταβλητή ls_kodyvar έχει καταχωρηθεί, συνέχεια από την επόμενη
			if	if_kodyvar_exists(ls_kodyvar) then continue
		
		row = dw.getrow()
		
		dw.object.kodypal[row] = ll_kodypal
		dw.object.kodyvar[row] = ls_kodyvar
		dw.object.kodxrisi[row] = gs_kodxrisi
		dw.object.expr[row] = ls_expr
		dw.object.aa[row] = li_aa
		
		if_insertrow()
		row = row + 1
		dw.setrow(row)
		
	next		// Επόμενη μεταβλητή
		
		
// clean-up
	destroy ds
end event

