HA$PBExportHeader$w_pbgrid.srw
$PBExportComments$
forward
global type w_pbgrid from window
end type
type dw_main from datawindow within w_pbgrid
end type
end forward

global type w_pbgrid from window
integer width = 2007
integer height = 1720
boolean titlebar = true
string menuname = "m_main_pbgrid"
boolean controlmenu = true
boolean minbox = true
boolean resizable = true
long backcolor = 67108864
string icon = "AppIcon!"
boolean center = true
event me_refresh ( )
event me_save ( )
event me_delrec ( )
event me_selrec ( )
event me_movetonew ( )
event me_movetofirst ( )
event me_movetolast ( )
event me_movetonext ( )
event me_movetoprev ( )
event me_selectall ( )
event me_cut ( )
event me_copy ( )
event me_paste ( )
event me_clear ( )
event me_undo ( )
event me_close ( )
event ie_exit ( )
event ie_checkmenu ( )
event me_find ( )
dw_main dw_main
end type
global w_pbgrid w_pbgrid

type variables
protected boolean	ib_edit, &
						ib_newrec
						
// Alternative row coloring
protected long		il_rowcolor  = rgb(255,255,255) 
protected long		il_rowrcolor = rgb(255,255,128)

// Έλεγχος δικαιωμάτων
protected string	is_tablename
end variables

forward prototypes
public subroutine of_initrow (ref datawindow adw, long row)
public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor)
public function boolean of_checkdelete (ref datawindow adw, long row)
public subroutine if_insertrow ()
public function long if_retrieve ()
public function boolean if_update ()
public subroutine of_postinitrow (ref datawindow adw, long row)
public subroutine if_checkmodified (long row)
public function boolean of_check4required (ref datawindow adw, long row)
public subroutine of_setmasks ()
public subroutine of_open ()
end prototypes

event me_refresh();dw_main.SetRedraw(false)
if_retrieve()
dw_main.SetRow(1)
dw_main.SelectRow(0, false)
dw_main.SelectRow(1, true)
dw_main.SetRedraw(true)
end event

event me_save();if_update()
end event

event me_delrec();// Διαγραφή τρέχουσας εγγραφής ή όλων των επιλεγμένων

integer	li_ret
long		ll_currentrow, ll_firstselected, ll_nextselected, ll_nrows

// Έλεγχος δικαιωμάτων
	if not fn_perm(is_tablename, "delrec") then return

// Ανανέωση των δεδομένων
	if_update()

// Παίρνουμε την τρέχουσα εγγραφή, το σύνολο των εγγραφών και την πρώτη επιλεγμένη
	ll_currentrow = dw_main.getrow()
	ll_firstselected = dw_main.GetSelectedRow(0)
	ll_nrows = dw_main.rowcount()
	
// -----------------------------------------------------------------------------
// Δεν υπάρχουν επιλεγμένες εγγραφές - Διαγραφή τρέχουσας
// -----------------------------------------------------------------------------
	
	if ll_firstselected = 0 then
		
		// Αν δεν υπάρχει τρέχουσα εγγραφή ή είναι η τελευταία (new record) 
		// δεν διαγράφουμε
		if ll_currentrow = 0 or ll_currentrow = ll_nrows then return
		
		// Check for delete rules
		if not of_checkdelete(dw_main, ll_currentrow) then return
		
		// Επαλήθευση
		li_ret = MessageBox(trn(223), trn(456), Exclamation!, OKCancel!, 2)
		if not li_ret = 1 then return
		
		// Διαγραφή τρέχουσας εγγραφής (υπάρχει και δεν είναι η τελευταία)
		dw_main.SetRedraw(false)
		dw_main.deleterow(ll_currentrow)
		ib_edit = true		// to allow if_update() to proceed
		if_update()			// reset ib_newrec, ib_edit
		
		// Επιλογή προηγούμενης
		ll_currentrow = ll_currentrow - 1
		if ll_currentrow = 0 then ll_currentrow = 1
		dw_main.SetRow(ll_currentrow)
		dw_main.ScrollToRow(ll_currentrow)
		
		// Επιστροφή
		dw_main.SetRedraw(true)
		
		this.TriggerEvent("ie_checkmenu")
		
		return
		
	end if	// if ll_firstselected = 0

// -----------------------------------------------------------------------------
// Υπάρχουν επιλεγμένες εγγραφές - Διαγραφή όλων
// -----------------------------------------------------------------------------
	
	ll_nextselected = ll_firstselected
	
	// Το μύνημα επαλήθευσης εμφανίζεται μία φορά για όλες τις επιλεγμένες εγγραφές
	// Αν η πρώτη επιλεγμένη εγγραφή είναι η τελευταία (new record)
	// δεν διαγράφεται ούτε εμφανίζεται το μήνυμα
	if ll_nextselected = ll_nrows then return
	li_ret = MessageBox(trn(224), trn(457), Exclamation!, OKCancel!, 2)
	if not li_ret = 1 then return	
	
	dw_main.SetRedraw(false)
	
	do while not ll_nextselected = 0
	
		// Αν είναι η τελευταία (new record) δεν την διαγράφουμε
		// (χρησιμοποιούμε την rowcount() για να
		// επαναυπολογίζουμε μετά από κάθε διαγραφή)
		if ll_nextselected = dw_main.rowcount() then exit
		
		// Check for delete rules 
		// Διακοπή της διαγραφής στην πρώτη εγγραφή όπου of_checkdelete() = false
		if not of_checkdelete(dw_main, ll_nextselected) then exit
		
		// Διαγραφή τρέχουσας επιλογής (υπάρχει και δεν είναι η τελευταία)
		dw_main.deleterow(ll_nextselected)
		ib_edit = true		// to allow if_update() to proceed
		if_update()			// reset ib_newrec, ib_edit
		
		// Παίρνουμε την επόμενη επιλογή 
		// (πάλι από την αρχή)
		ll_nextselected = dw_main.GetSelectedRow(0)

	loop

// Επιλέγουμε την προηγούμενη μετά την πρώτη επιλεγμένη
		ll_currentrow = ll_firstselected - 1
		if ll_currentrow = 0 then ll_currentrow = 1
		dw_main.SetRow(ll_currentrow)
		dw_main.ScrollToRow(ll_currentrow)

// Καθαρίζουμε την επιλογή (ίσως μείνει η τελευταία επιλεγμένη)
	dw_main.SelectRow(0, false)
	dw_main.SetRedraw(true)
	
	this.TriggerEvent("ie_checkmenu")
	

	
end event

event me_selrec();// Επιλογή της τρέχουσας εγγραφής
// (από επιλογή τυχόν προηγούμενης)
	long	ll_currentrow
	ll_currentrow = dw_main.getrow()
	if ll_currentrow = 0 then return
	
	dw_main.SelectRow(0, false)
	dw_main.SelectRow(ll_currentrow, true)
	
	
end event

event me_movetonew();// Μετακίνηση σε νέα εγγραφή
	long	ll_newrow
	ll_newrow = dw_main.rowcount()
	
	dw_main.SelectRow(0, false)	// Καθαρισμός επιλογής
	
	dw_main.SetColumn(1)
	dw_main.ScrolltoRow(ll_newrow)
	
	

end event

event me_movetofirst();// Μετακίνηση στην πρώτη εγγραφή

	dw_main.SelectRow(0, false)	// Καθαρισμός επιλογής
	
	dw_main.SetColumn(1)
	dw_main.ScrolltoRow(1)
	

end event

event me_movetolast();// Μετακίνηση στην τελευταία εγγραφή
// (Στην ουσία είναι η προτελευταία αφού η τελευταία είναι η νέα)
	
	long	ll_lastrow
	
	ll_lastrow = dw_main.rowcount() - 1
	
	dw_main.SelectRow(0, false)	// Καθαρισμός επιλογής
	
	dw_main.ScrolltoRow(ll_lastrow)
	

end event

event me_movetonext();// Μετακίνηση στην επόμενη εγγραφή
// (αν δεν είμαστε στην τελευταία)
	
	long	ll_row
	
	ll_row = dw_main.getrow()

	if ll_row = dw_main.rowcount() then return	// είμαστε στην τελευταία
	
	dw_main.SelectRow(0, false)	// Καθαρισμός επιλογής
	
	dw_main.ScrolltoRow(ll_row + 1)
	

end event

event me_movetoprev();// Μετακίνηση στην προηγούμενη εγγραφή
// (αν δεν είμαστε στην πρώτη)

	long	ll_row
	
	ll_row = dw_main.getrow()
	
	if ll_row <= 1 then return		// είμαστε στην πρώτη
	
	dw_main.SelectRow(0, false)	// Καθαρισμός επιλογής
	
	dw_main.ScrolltoRow(ll_row - 1)

end event

event me_selectall();// Επιλογή όλων των εγγραφών
// εκτώς από την τελευταία
	dw_main.SetRedraw(false)

	dw_main.SelectRow(0, true)
	dw_main.SelectRow(dw_main.rowcount(), false)
	
	dw_main.SetRedraw(true)
	
end event

event me_cut();// Αποκοπή

	dw_main.cut()
end event

event me_copy();// Αντιγραφή

	dw_main.copy()
end event

event me_paste();// Επικόλληση

	dw_main.paste()
end event

event me_clear();// Καθαρισμός (διαγραφή)
	
	dw_main.clear()
end event

event me_undo();// Αναίρεση

	dw_main.undo()
end event

event me_close();// Κλείσιμο παραθύρου

	close(this)
end event

event ie_exit();// terminate the application

	close(parentwindow())
end event

event ie_checkmenu();// Enable - disable menu items based on current record

	MenuID.EVENT TRIGGER DYNAMIC ie_checkmenu(dw_main)
end event

event me_find();// Εύρεση κειμένου

// Άνοιγμα του w_gridfind με το dw_main σαν παράμετρο
	OpenWithParm(w_gridfind, dw_main)
end event

public subroutine of_initrow (ref datawindow adw, long row);// Initialize new row
end subroutine

public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor);// Set alternate colors

end subroutine

public function boolean of_checkdelete (ref datawindow adw, long row);// Check for delete rules for the current row

	return true
end function

public subroutine if_insertrow ();// Insert a new row at the end
	long	ll_newrow
	ll_newrow =	dw_main.Insertrow(0)
	
// Initialize but clear modified flag
	of_initrow(dw_main, ll_newrow)
	dw_main.SetItemStatus(ll_newrow, 0, Primary!, NotModified!)
	
	this.triggerevent("ie_checkmenu")
	
	
end subroutine

public function long if_retrieve ();// Override if retrieval arguments required
// returns the number of rows
	
	long	ll_nrows
	
	ll_nrows = dw_main.retrieve()
	
	return ll_nrows
end function

public function boolean if_update ();// update dw_main (return true if succeded)
	long	ll_row
	integer	li_ret
	
// Update only when ib_edit = true
// Return true to allow row changing
	if not ib_edit then return true
		
	dw_main.AcceptText()

// Check for required field and update
	ll_row = dw_main.getrow()
	if ll_row > 0 and ll_row < dw_main.rowcount() then 
		if not of_check4required(dw_main, ll_row) then return false
	end if
	li_ret = dw_main.update()
	if li_ret <> 1 then return false
	
// Clear flags and commit
	ib_newrec = false
	commit using sqlca;
	
	return true
end function

public subroutine of_postinitrow (ref datawindow adw, long row);// Initialize row after edit has started
// usefull for autonumber
end subroutine

public subroutine if_checkmodified (long row);// Checks if row has been modified and sets ib_edit

// Check row status
	dwitemstatus	li_rowstatus
	dw_main.AcceptText()

	li_rowstatus = dw_main.GetItemStatus(row, 0, primary!)
	
// if row has been modified
	if li_rowstatus = DataModified! or li_rowstatus = NewModified! then
	
		// Set edit flag (for update to be allowed)
			ib_edit = true
	
		// if this is the last row add an empty one and set newrec flag
		// call of_postinitrow()
			if row = dw_main.rowcount() then
				of_postinitrow(dw_main, row)
				if_insertrow()
				ib_newrec = true
			end if	
			
	end if
end subroutine

public function boolean of_check4required (ref datawindow adw, long row);/*
string	lstring	
long		ll_fount
long		llong	
date		ldate
time		ltime

// string
	lstring = adw.object.xxx[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, ".....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if
	
	// Έλεγχος αν ο κωδικός υπάρχει
		ll_found = adw.find("xxx = '" + lstring + "'", 1, adw.rowcount())
		if ll_found = row then ll_found = adw.find("xxx = '" + lstring + "'", ll_found + 1, adw.rowcount())
		if ll_found > 0 and ll_found <> row then
			MessageBox(gs_app_name, "Code exists")
			adw.setfocus()
			adw.Setcolumn("xxx")
			return false
		end if	

// long
	llong	= adw.object.xxx[row]
	if isnull(llong) then
		Messagebox(gs_app_name, ".....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if
	
// date
	ldate	= adw.object.xxx[row]
	if isnull(ldate) then
		Messagebox(gs_app_name, ".....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if	
	
// time
	ltime	= adw.object.xxx[row]
	if isnull(ltime) then
		Messagebox(gs_app_name, ".....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if	

*/
	
// everything ok
	return true
end function

public subroutine of_setmasks ();// Edit Mask & display Mask

/*

// maskdate, maskdateedit
	fn_seteditmask(dw_main, "xxxxx", fn_param_maskdateedit())
	fn_setformatmask(dw_main, "xxxxx", fn_param_maskdate())

// maskposo, maskposoedit
	fn_seteditmask(dw_main, "xxxxx", fn_param_maskposoedit())
	fn_setformatmask(dw_main, "xxxxx", fn_param_maskposo())
	
// maskposotita, maskposotitaedit
	fn_seteditmask(dw_main, "xxxxx", fn_param_maskposotitaedit())
	fn_setformatmask(dw_main, "xxxxx", fn_param_maskposotita())

// masktime, masktimeedit
	fn_seteditmask(dw_main, "xxxxx", fn_param_masktimeedit())
	fn_setformatmask(dw_main, "xxxxx", fn_param_masktime())

*/
end subroutine

public subroutine of_open ();// Εκτελείται αμέσως μετά το άνοιγμα
end subroutine

on w_pbgrid.create
if this.MenuName = "m_main_pbgrid" then this.MenuID = create m_main_pbgrid
this.dw_main=create dw_main
this.Control[]={this.dw_main}
end on

on w_pbgrid.destroy
if IsValid(MenuID) then destroy(MenuID)
destroy(this.dw_main)
end on

event open;// open 
	of_open()

// Initialize dw_main
	dw_main.SetTransObject(sqlca)
	if_retrieve()
	Move(0,0)
	
/*
// Make selected row appear sunken
	string	ls_ncols
	integer	li_ncols, i
	ls_ncols = dw_main.Object.DataWindow.Column.Count
	li_ncols = integer(ls_ncols)
	for i = 1 to li_ncols
		dw_main.Modify("#"+ string(i) + ".Border='0~tif(getrow() = currentrow(), 5, 0)'")
	next
*/

// Make alternative row coloring
	of_setrowcolors(il_rowcolor, il_rowrcolor)
	dw_main.Modify("DataWindow.Detail.Color= '536870912~tif(mod(getrow(), 2) = 1, " + string(il_rowcolor) + ", " + string(il_rowrcolor) + ")'")
	
// Έλεγχος δικαιωμάτων
	if not fn_perm(is_tablename, "UPDATE") then dw_main.enabled = false
	
// Set masks
	of_setmasks()
	
end event

event closequery;// update dw_main (if failed prevent closing)
	if not if_update() then 
		dw_main.setfocus()
		return 1
	end if
end event

event resize;dw_main.width = this.WorkSpaceWidth()
dw_main.Height = this.WorkSpaceHeight()
end event

type dw_main from datawindow within w_pbgrid
event ue_keydown pbm_dwnkey
event ue_lbuttonup pbm_dwnlbuttonup
integer width = 1961
integer height = 1480
integer taborder = 10
string title = "none"
boolean hscrollbar = true
boolean vscrollbar = true
borderstyle borderstyle = stylelowered!
end type

event ue_keydown;long	ll_row

choose case key
		
	case KeyEscape!	// Αν είμαστε σε νέα εγγραφή διαγραφή της
		ll_row = this.getrow()
		if ib_newrec then
			this.deleterow(ll_row)
			ib_newrec = false
			ib_edit = false
			getparent().TriggerEvent("ie_checkmenu")
		end if
				
end choose
end event

event ue_lbuttonup;// Check if row has been modified
	this.AcceptText()		
	if_checkmodified(row)
end event

event retrieveend;// Insert a new record at the end
	if_insertrow()
	
// reset flags	
	ib_edit = false
	ib_newrec = false
end event

event editchanged;if_checkmodified(row)
		
end event

event rowfocuschanging;// update - if failed prevent row changing
	
	if not if_update() then
		dw_main.setfocus()
		return 1
	else	
		selectrow(currentrow, false)
		selectrow(newrow, true)
	
	end if
	
end event

event clicked;// Καθαρισμός επιλεγμένων εγγραφών
// Αν είναι πατημένο το ctrl πολλαπλή επιλογή
// Δεν επιλέγουμε την τελευταία (νέα) εγγραφή
// Αν η εγγραφή είναι ήδη επιλεγμένη την αποεπιλέγουμε
	if keydown(KeyControl!) then 
		if row < dw_main.rowcount() then
			if dw_main.IsSelected(row) then
				dw_main.SelectRow(row, false)
			else
				dw_main.SelectRow(row, true)
			end if
		end if
	else
		dw_main.SelectRow(0, false)
	end if
	
	
// ----------------------------------------------------------------------	
// Ταξινόμηση
// ----------------------------------------------------------------------	

String	ls_old_sort, ls_column
char		lc_sort

// Έλεγχος αν επιτρέπεται η ταξινόμηση
	//if not ib_sort then return

// Check whether the user clicks on the column header
	if Right(dwo.name,2) = '_t' then
		ls_column = left(dwo.name, len(string(dwo.name))-2)
		
		// delete the last empty row (new rec)
		// to not be included in sorting
			dw_main.SetRedraw(false)
			dw_main.DeleteRow(dw_main.rowcount())
		
		// Get old sort, if any
			ls_old_sort = dw_main.Describe("Datawindow.Table.sort")
			
		// Check whether previously sorted columhn and currently clicked
		// column are same or not. If both are same then check for the sort
		// order of previously sorted column (A - Asc, D - Desc) and change it.
		// If both are not same then simply sort it by Ascending order
			if ls_column = left(ls_old_sort, len(ls_old_sort)-2) then
				lc_sort = right(ls_old_sort,1)
				if lc_sort = 'A' then 
					lc_sort = 'D'
				else
					lc_sort = 'A'
				end if
				dw_main.SetSort(ls_column + " " + lc_sort)
			else
				dw_main.SetSort(ls_column + " A")
			end if
		dw_main.Sort()
		
		// Select firt row
			dw_main.SetRow(1)
			dw_main.ScrollToRow(1)
			
		// Insert the deleted new row again
			if_insertrow()
			dw_main.SetRedraw(true)

	end if
end event

event rowfocuschanged;// check menu
	
	getparent().TriggerEvent("ie_checkmenu")
end event

event itemchanged;if_checkmodified(row)
end event

