HA$PBExportHeader$uo_misth_fylo_epidom_grid.sru
$PBExportComments$
forward
global type uo_misth_fylo_epidom_grid from u_grid
end type
type pb_expr from picturebutton within uo_misth_fylo_epidom_grid
end type
end forward

global type uo_misth_fylo_epidom_grid from u_grid
integer width = 2542
integer height = 936
string is_tablename = "misth_ypal_epidom"
pb_expr pb_expr
end type
global uo_misth_fylo_epidom_grid uo_misth_fylo_epidom_grid

type variables
w_misth_fylo_form	iw_parent

string	is_kodepidom_prev
end variables

forward prototypes
public subroutine of_postinitrow (ref datawindow adw, long row)
public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor)
public function boolean of_check4required (ref datawindow adw, long row)
public subroutine ev_kodepidom_changed (long row, string old, string new)
end prototypes

public subroutine of_postinitrow (ref datawindow adw, long row);adw.object.kodfylo[row] = iw_parent.idw_main.object.kodfylo[1]
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
	lstring = adw.object.kodepidom[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, trn(200))
		adw.setfocus()
		adw.setcolumn("kodepidom")
		return false
	end if
	
	// Έλεγχος αν ο κωδικός υπάρχει
		ll_found = adw.find("kodepidom = '" + lstring + "'", 1, adw.rowcount())
		if ll_found = row then ll_found = adw.find("kodepidom = '" + lstring + "'", ll_found + 1, adw.rowcount())
		if ll_found > 0 and ll_found <> row then
			MessageBox(gs_app_name, trn(131))
			adw.setfocus()
			adw.Setcolumn("kodepidom")
			return false
		end if		

// everything ok
	return true
end function

public subroutine ev_kodepidom_changed (long row, string old, string new);// Το kodepidom της γραμμής row έχει αλλάξει από old σε new
// Αλλάζουμε και τις αναφορές

	
// Αν το προηγούμενο kodepidom είναι κενό, σημαίνει ότι 
// είμαστε σε νέα εισαγωγή.
	if is_kodepidom_prev = "" or isnull(is_kodepidom_prev) then return
	
// Αν είναι νέο και προηγούμενο είναι ίδια, επιστρέφουμε
	if old = new then return
	
// Αλλάζουμε τις αναφορές για τα επιδόματα κάτω από την τρέχουσα γραμμή
	string	ls_expr
	long		i
	long		ll_rows
	string	ls_oldepidom
	string	ls_newepidom
	
	ll_rows = dw.rowcount()
	
	for i = row + 1 to ll_rows - 1		// Η τελευταία είναι η κενή για εισαγωγή
		
		ls_expr = dw.object.expr[i]
		ls_oldepidom = "[" + old + "]"
		ls_newepidom = "[" + new + "]"
		
		ls_expr = fn_replace_str(ls_expr, ls_oldepidom, ls_newepidom)
		
		dw.object.expr[i] = ls_expr

	next
	
// Αλλαγή αναφορών σε όλες τις κρατήσεις
	datawindow	ldw_krat

	ldw_krat = iw_parent.idw_krat
	
	ll_rows = ldw_krat.rowcount()
	
	for i = 1 to ll_rows - 1			// Η τελευταία είναι η κενή για εισαγωγή
		
		ls_expr = ldw_krat.object.expr[i]

		ls_oldepidom = "[" + old + "]"
		ls_newepidom = "[" + new + "]"
		
		ls_expr = fn_replace_str(ls_expr, ls_oldepidom, ls_newepidom)
		
		ldw_krat.object.expr[i] = ls_expr

	next
	
end subroutine

on uo_misth_fylo_epidom_grid.create
int iCurrent
call super::create
this.pb_expr=create pb_expr
iCurrent=UpperBound(this.Control)
this.Control[iCurrent+1]=this.pb_expr
end on

on uo_misth_fylo_epidom_grid.destroy
call super::destroy
destroy(this.pb_expr)
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

type pb_selectall from u_grid`pb_selectall within uo_misth_fylo_epidom_grid
integer x = 2267
end type

type pb_selectrow from u_grid`pb_selectrow within uo_misth_fylo_epidom_grid
integer x = 2153
end type

type pb_new from u_grid`pb_new within uo_misth_fylo_epidom_grid
integer x = 1989
end type

type pb_last from u_grid`pb_last within uo_misth_fylo_epidom_grid
integer x = 1865
end type

type pb_next from u_grid`pb_next within uo_misth_fylo_epidom_grid
integer x = 1751
end type

type pb_previous from u_grid`pb_previous within uo_misth_fylo_epidom_grid
integer x = 1637
end type

type pb_first from u_grid`pb_first within uo_misth_fylo_epidom_grid
integer x = 1522
end type

type pb_delete from u_grid`pb_delete within uo_misth_fylo_epidom_grid
integer x = 2432
end type

type dw from u_grid`dw within uo_misth_fylo_epidom_grid
event ue_dwndropdown pbm_dwndropdown
integer width = 2537
integer height = 820
string dataobject = "dw_misth_fylo_epidom_list"
end type

event dw::ue_dwndropdown;// drop down - hold value of kodepidom

if this.GetColumnName() <> "kodepidom" then return

long		ll_row
ll_row = this.getrow()

is_kodepidom_prev = this.object.kodepidom[ll_row]

end event

event dw::itemchanged;call super::itemchanged;choose case dwo.name
		
	case "kodepidom"
		
		// Παίρνουμε την έκφραση από misth_zpepidom
			string		ls_expr
			
			select expr into :ls_expr
			from  misth_zpepidom
			where kodepidom = :data and kodxrisi = :gs_kodxrisi;
			fn_sqlerror()
			
			this.object.expr[row] = ls_expr
			
		// Αλλαζουμε τις αναφορές στα άλλα επιδόματα και στις κρατήσεις
			ev_kodepidom_changed(row, is_kodepidom_prev, data)
			
 
end choose
end event

type pb_expr from picturebutton within uo_misth_fylo_epidom_grid
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

// Φόρτωμα όλων των μεταβλητών υπαλλήλων
	datastore		lds_yvar
	lds_yvar = fn_createds_zpyvar_all()

// Φόρτωμα είδη υπάρχοντων επιδομάτων
	datastore		lds_epidom
	lds_epidom = fn_createds_zpepidom(dw)

// Μεταφορά σε structure και άνοιγμα w_expr
	s_expr	lsc_expr
	
	if lds_stath.rowcount() > 0 then
		lsc_expr.stath = lds_stath
	end if

	if lds_yvar.rowcount() > 0 then
		lsc_expr.yvar = lds_yvar
	end if
	
	if lds_epidom.rowcount() > 0 then
		lsc_expr.epidom = lds_epidom
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
	destroy lds_epidom
			
		

end event

