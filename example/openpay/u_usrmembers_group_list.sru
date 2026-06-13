HA$PBExportHeader$u_usrmembers_group_list.sru
$PBExportComments$
forward
global type u_usrmembers_group_list from ucv_buttons_dw
end type
type st_1 from statictext within u_usrmembers_group_list
end type
end forward

global type u_usrmembers_group_list from ucv_buttons_dw
integer width = 1911
integer height = 1068
boolean ib_selection = true
string is_formwin = "w_usrmembers_group_form"
string is_tablename = "usrusers"
boolean ib_sort = true
st_1 st_1
end type
global u_usrmembers_group_list u_usrmembers_group_list

type variables
w_usrGroups_form		iw_parent
end variables

forward prototypes
public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor)
protected subroutine of_reset_struct ()
protected subroutine of_init_struct ()
protected subroutine of_dw2struct (ref datawindow adw, long row)
protected subroutine of_struct2dw (ref datawindow adw, long row)
public subroutine of_afterinsert (ref datawindow adw, long row)
public subroutine of_afterupdate (ref datawindow adw, long row)
end prototypes

public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor);al_rowrcolor = rgb(255,255,128)
end subroutine

protected subroutine of_reset_struct ();setnull(gsc_usrMembers.koduser)
setnull(gsc_usrMembers.kodgroup)
end subroutine

protected subroutine of_init_struct ();gsc_usrMembers.kodgroup = iw_parent.il_kodgroup
end subroutine

protected subroutine of_dw2struct (ref datawindow adw, long row);gsc_usrMembers.koduser = adw.object.koduser[row]
gsc_usrMembers.kodgroup = adw.object.kodgroup[row]
end subroutine

protected subroutine of_struct2dw (ref datawindow adw, long row);adw.object.koduser[row] = gsc_usrMembers.koduser
adw.object.kodgroup[row] = gsc_usrMembers.kodgroup 

// Συνδεδεμένα
	string	ls_username, ls_fullname
	integer	li_isactive
	
	select username, fullname, isactive
	into     :ls_username, :ls_fullname, :li_isactive
	from	  usrusers
	where koduser = :gsc_usrmembers.koduser;
	fn_sqlerror()
	
	adw.object.usrusers_username[row] = ls_username
	adw.object.usrusers_fullname[row] = ls_fullname
	adw.object.usrusers_isactive[row] = li_isactive
	
end subroutine

public subroutine of_afterinsert (ref datawindow adw, long row);// Ελέγχουμε αν ο νέος χρήστης υπάρχει ήδη στο adw
// Αν υπάρχει διαγράφουμε την τρέχουσα γραμμή και επιστρέφουμε
	long	ll_rows, i, temp
	ll_rows = adw.rowcount()
	
	for i = 1 to ll_rows
		if i <> row then
			
			if adw.object.koduser[i] = gsc_usrMembers.koduser then
				
				MessageBox(trn(239), trn(136))
				
				// Διαγραφή της νέας γραμμής και επιλογή της προηγούμενης
					adw.SetRedraw(false)
					adw.DeleteRow(row)
					row = row - 1
					if row > 0 then
						adw.SetRow(row)
						adw.ScrollToRow(row)
					else
						row = 1
						adw.SetRow(row)
					end if
	
				// Αν επιτρέπεται η επιλογή (ib_selection) επιλέγουμε την νέα γραμμή
					if ib_selection then
						adw.SelectRow(0, false)
						adw.SelectRow(row, true)
					end if
				
				adw.SetRedraw(true)
				return
			
			end if
		
		end if
		
	next
	

end subroutine

public subroutine of_afterupdate (ref datawindow adw, long row);// Απλώς καλούμε την of_afterinsert()

	of_afterinsert(adw, row)
end subroutine

on u_usrmembers_group_list.create
int iCurrent
call super::create
this.st_1=create st_1
iCurrent=UpperBound(this.Control)
this.Control[iCurrent+1]=this.st_1
end on

on u_usrmembers_group_list.destroy
call super::destroy
destroy(this.st_1)
end on

type dw from ucv_buttons_dw`dw within u_usrmembers_group_list
integer width = 1902
integer height = 940
string dataobject = "dw_usrmembers_group_list"
end type

type pb_delete from ucv_buttons_dw`pb_delete within u_usrmembers_group_list
integer x = 1797
end type

type pb_edit from ucv_buttons_dw`pb_edit within u_usrmembers_group_list
integer x = 1678
end type

type pb_add from ucv_buttons_dw`pb_add within u_usrmembers_group_list
integer x = 1559
end type

type st_1 from statictext within u_usrmembers_group_list
integer y = 12
integer width = 722
integer height = 64
boolean bringtotop = true
integer textsize = -9
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial Greek"
long textcolor = 16711680
long backcolor = 67108864
string text = trn(684) + " - " + trn(430) + ":"
boolean focusrectangle = false
end type

