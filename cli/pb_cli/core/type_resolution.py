"""Pure type resolution and call resolution — no I/O dependencies."""

from __future__ import annotations

import json

from pb_cli.core.ast_walker import walk_tagged
from pb_cli.core.models import (
    CallRow,
    GlobalVarRow,
    LocalVarRow,
    ProcedureRow,
    ResolvedCallRow,
    ResolvedTypeRow,
)

PRIMITIVES = frozenset({
    "string", "integer", "long", "boolean", "double", "decimal",
    "date", "time", "datetime", "blob", "char", "real", "unsigned",
    "byte", "int",
})

PB_BUILTINS = frozenset({
    "datawindow", "datastore", "datawindowchild", "window",
    "pointer", "transaction", "dynamicdescriptionarea",
    "error", "message", "powerobject", "structure",
    "treeviewitem", "dwitemstatus", "menu",
})

PB_BUILTIN_CALLS = frozenset({
    # Free functions — callable from any context
    "trn", "isnull", "setnull", "messagebox", "rgb",
    "abs", "ceiling", "fact", "max", "min", "mod", "round", "sign",
    "today", "now", "year", "month", "day", "hour", "minute", "second",
    "daysafter", "relativedate", "relativetime",
    "string", "integer", "long", "double", "real", "dec", "date",
    "time", "datetime", "blob",
    "len", "left", "right", "mid", "trim", "lower", "upper",
    "lefttrim", "righttrim",
    "pos", "posrev", "match", "replace",
    "space", "fill", "reverse", "char", "asc",
    "upperbound", "lowerbound",
    "timer", "idle", "yield", "post", "send",
    "fileopen", "fileread", "filewrite", "fileclose",
    "filedelete", "filecopy", "filerename",
    "createdirectory", "directoryexists", "fileexists",
    "getcurrentdirectory",
    "debugbreak",
    "getenvironment", "clipboard",
    "getfileopenname", "getfilesavename",
    "isnumber", "isdate", "istime",
    "open", "close", "closewithreturn",
    "run", "print",
    "syntaxfromsql",
    "classname", "isvalid",
})

# Methods scoped to specific PB classes — resolved via receiver-type tracing.
# Auto-extracted from doc/pb2025r2 HTML docs via BeautifulSoup.
# Regenerate: cd cli && python3 -c "from pb_cli.core.type_resolution import PB_CLASS_METHODS; print('ok')"
PB_CLASS_METHODS: dict[str, frozenset[str]] = {
    "animation": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "play", "pointerx", "pointery", "postevent", "resize", "seek", "setfocus", "setposition", "setredraw", "show", "stop", "triggerevent", "typeof"}),
    "application": frozenset({"beginsession", "classname", "getcontextservice", "gethttprequestheader", "gethttprequestheaders", "gethttpresponseheaders", "gethttpresponsestatuscode", "gethttpresponsestatustext", "getparent", "getpowerserverurl", "getquickaccesstoolbarstatuspath", "getsessionid", "postevent", "sethighdpimode", "sethttprequestheader", "setlibrarylist", "setpowerserverurl", "setquickaccesstoolbarstatuspath", "settranspool", "triggerevent", "typeof"}),
    "checkbox": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "commandbutton": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "datastore": frozenset({"accepttext", "categorycount", "categoryname", "classname", "clearvalues", "clipboard", "copyrtf", "create", "createfrom", "datacount", "dbcancel", "deletedcount", "deleterow", "describe", "expand", "expandall", "expandallchildren", "expandlevel", "exportjson", "exportrowasjson", "filter", "filteredcount", "find", "findcategory", "findgroupchange", "findrequired", "findseries", "generatehtmlform", "generateresultset", "getborderstyle", "getchanges", "getchild", "getclickedcolumn", "getclickedrow", "getcolumn", "getcolumnname", "getcontextservice", "getdata", "getdatapieexplode", "getdatastyle", "getdatavalue", "getdwobject", "getformat", "getfullstate", "getitemdate", "getitemdatetime", "getitemdecimal", "getitemnumber", "getitemstatus", "getitemstring", "getitemtime", "getnextmodified", "getparent", "getrow", "getrowfromrowid", "getrowidfromrow", "getselectedrow", "getseriesstyle", "getsqlselect", "getstatestatus", "gettext", "gettrans", "getvalidate", "getvalue", "groupcalc", "importclipboard", "importfile", "importjson", "importjsonbykey", "importrowfromjson", "importstring", "insertdocument", "insertrow", "isselected", "modifiedcount", "modify", "pastertf", "postevent", "print", "printcancel", "reselectrow", "reset", "resetdatacolors", "resettransobject", "resetupdate", "retrieve", "rowcount", "rowscopy", "rowsdiscard", "rowsmove", "saveas", "saveasascii", "savenativepdftoblob", "selectrow", "seriescount", "seriesname", "setborderstyle", "setchanges", "setcolumn", "setdatapieexplode", "setdatastyle", "setdetailheight", "setfilter", "setformat", "setfullstate", "sethtmlaction", "setitem", "setitemstatus", "setposition", "setrow", "setseriesstyle", "setsort", "setsqlpreview", "setsqlselect", "settext", "settrans", "settransobject", "setvalidate", "setvalue", "setwsobject", "sharedata", "sharedataoff", "sort", "triggerevent", "typeof", "update"}),
    "datawindow": frozenset({"accepttext", "canundo", "categorycount", "categoryname", "classname", "clear", "clearvalues", "clipboard", "copy", "copyrtf", "create", "crosstabdialog", "cut", "datacount", "dbcancel", "dberrorcode", "dberrormessage", "deletedcount", "deleterow", "describe", "drag", "expand", "expandall", "expandallchildren", "expandlevel", "exportjson", "exportrowasjson", "filter", "filteredcount", "find", "findcategory", "findgroupchange", "findnext", "findrequired", "findseries", "generatehtmlform", "generateresultset", "getbandatpointer", "getborderstyle", "getchanges", "getchild", "getclickedcolumn", "getclickedrow", "getcolumn", "getcolumnname", "getcontextservice", "getdata", "getdatalabelling", "getdatapieexplode", "getdatastyle", "getdatatransparency", "getdatavalue", "getdwobject", "getformat", "getfullstate", "getitemdate", "getitemdatetime", "getitemdecimal", "getitemnumber", "getitemstatus", "getitemstring", "getitemtime", "getmessagetext", "getnextmodified", "getobjectatpointer", "getparent", "getrow", "getrowfromrowid", "getrowidfromrow", "getselectedrow", "getserieslabelling", "getseriesstyle", "getseriestransparency", "getsqlpreview", "getsqlselect", "getstatestatus", "gettext", "gettrans", "getupdatestatus", "getvalidate", "getvalue", "groupcalc", "hide", "importclipboard", "importfile", "importjson", "importjsonbykey", "importrowfromjson", "importstring", "insertdocument", "insertrow", "isselected", "linecount", "modifiedcount", "modify", "move", "objectatpointer", "oleactivate", "paste", "pastertf", "pointerx", "pointery", "position", "postevent", "print", "printcancel", "replacetext", "reselectrow", "reset", "resetdatacolors", "resettransobject", "resetupdate", "resize", "retrieve", "rowcount", "rowscopy", "rowsdiscard", "rowsmove", "saveas", "saveasascii", "saveasformattedtext", "savedisplayeddataas", "saveink", "saveinkpic", "savenativepdftoblob", "scroll", "scrollnextpage", "scrollnextrow", "scrollpriorpage", "scrollpriorrow", "scrolltorow", "selectedlength", "selectedline", "selectedstart", "selectedtext", "selectrow", "selecttext", "selecttextall", "selecttextline", "selecttextword", "seriescount", "seriesname", "setactioncode", "setborderstyle", "setchanges", "setcolumn", "setdatalabelling", "setdatapieexplode", "setdatastyle", "setdatatransparency", "setdetailheight", "setfilter", "setfocus", "setformat", "setfullstate", "sethtmlaction", "setitem", "setitemstatus", "setposition", "setredraw", "setrow", "setrowfocusindicator", "setserieslabelling", "setseriesstyle", "setseriestransparency", "setsort", "setsqlpreview", "setsqlselect", "settaborder", "settext", "settrans", "settransobject", "setvalidate", "setvalue", "setwsobject", "sharedata", "sharedataoff", "show", "showheadfoot", "sort", "textline", "triggerevent", "typeof", "undo", "update"}),
    "datawindowchild": frozenset({"accepttext", "classname", "clearvalues", "crosstabdialog", "dbcancel", "dberrorcode", "dberrormessage", "deletedcount", "deleterow", "describe", "expand", "expandall", "expandallchildren", "expandlevel", "exportjson", "exportrowasjson", "filter", "filteredcount", "find", "findgroupchange", "getbandatpointer", "getborderstyle", "getchanges", "getchild", "getclickedcolumn", "getclickedrow", "getcolumn", "getcolumnname", "getcontextservice", "getformat", "getitemdate", "getitemdatetime", "getitemdecimal", "getitemnumber", "getitemstatus", "getitemstring", "getitemtime", "getnextmodified", "getobjectatpointer", "getparent", "getrow", "getrowfromrowid", "getrowidfromrow", "getselectedrow", "getsqlpreview", "getsqlselect", "gettext", "gettrans", "getupdatestatus", "getvalidate", "getvalue", "groupcalc", "importclipboard", "importfile", "importjson", "importjsonbykey", "importrowfromjson", "importstring", "insertrow", "isselected", "modifiedcount", "modify", "oleactivate", "reselectrow", "reset", "resettransobject", "resetupdate", "retrieve", "rowcount", "rowscopy", "rowsdiscard", "rowsmove", "saveas", "savenativepdftoblob", "scrollnextpage", "scrollnextrow", "scrollpriorpage", "scrollpriorrow", "scrolltorow", "selectrow", "setborderstyle", "setchanges", "setcolumn", "setdetailheight", "setfilter", "setformat", "setitem", "setitemstatus", "setposition", "setredraw", "setrow", "setrowfocusindicator", "setsort", "setsqlpreview", "setsqlselect", "settaborder", "settext", "settrans", "settransobject", "setvalidate", "setvalue", "setwsobject", "sharedata", "sharedataoff", "sort", "typeof", "update"}),
    "datepicker": frozenset({"classname", "drag", "getcalendar", "getcontextservice", "getparent", "gettext", "gettoday", "getvalue", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "settoday", "setvalue", "show", "triggerevent", "typeof"}),
    "dropdownlistbox": frozenset({"additem", "classname", "clear", "copy", "cut", "deleteitem", "dirlist", "dirselect", "drag", "finditem", "getcontextservice", "getparent", "hide", "insertitem", "move", "paste", "pointerx", "pointery", "position", "postevent", "print", "replacetext", "reset", "resize", "selectedlength", "selectedstart", "selectedtext", "selectitem", "selecttext", "setfocus", "setposition", "setredraw", "show", "text", "totalitems", "triggerevent", "typeof"}),
    "dropdownpicturelistbox": frozenset({"additem", "addpicture", "classname", "clear", "copy", "cut", "deleteitem", "deletepicture", "deletepictures", "dirlist", "dirselect", "drag", "finditem", "getcontextservice", "getparent", "hide", "insertitem", "move", "paste", "pointerx", "pointery", "position", "postevent", "print", "replacetext", "reset", "resize", "selectedlength", "selectedstart", "selectedtext", "selectitem", "selecttext", "setfocus", "setposition", "setredraw", "show", "text", "totalitems", "triggerevent", "typeof"}),
    "editmask": frozenset({"canundo", "classname", "clear", "copy", "cut", "drag", "getcontextservice", "getdata", "getparent", "hide", "linecount", "linelength", "move", "paste", "pointerx", "pointery", "position", "postevent", "print", "replacetext", "resize", "scroll", "selectedlength", "selectedline", "selectedstart", "selectedtext", "selecttext", "setfocus", "setmask", "setposition", "setredraw", "show", "textline", "triggerevent", "typeof", "undo"}),
    "groupbox": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "hprogressbar": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "offsetpos", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setrange", "setredraw", "show", "stepit", "triggerevent", "typeof"}),
    "hscrollbar": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "htrackbar": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "selectionrange", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "inkedit": frozenset({"classname", "clear", "copy", "cut", "drag", "getcontextservice", "getparent", "hide", "move", "paste", "pointerx", "pointery", "position", "postevent", "print", "recognizetext", "replacetext", "resize", "selectedlength", "selectedtext", "selecttext", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "inkpicture": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "loadink", "loadpicture", "move", "pointerx", "pointery", "postevent", "print", "resetink", "resetpicture", "resize", "save", "saveink", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "line": frozenset({"classname", "getcontextservice", "getparent", "hide", "move", "resize", "show", "typeof"}),
    "listbox": frozenset({"additem", "classname", "deleteitem", "dirlist", "dirselect", "drag", "finditem", "getcontextservice", "getparent", "hide", "insertitem", "move", "pointerx", "pointery", "postevent", "print", "reset", "resize", "selectedindex", "selecteditem", "selectitem", "setfocus", "setposition", "setredraw", "setstate", "settop", "show", "state", "text", "top", "totalitems", "totalselected", "triggerevent", "typeof"}),
    "listview": frozenset({"addcolumn", "additem", "addlargepicture", "addsmallpicture", "addstatepicture", "arrange", "classname", "deletecolumn", "deletecolumns", "deleteitem", "deleteitems", "deletelargepicture", "deletelargepictures", "deletesmallpicture", "deletesmallpictures", "deletestatepicture", "deletestatepictures", "drag", "editlabel", "finditem", "getcolumn", "getcontextservice", "getitem", "getorigin", "getparent", "hide", "insertcolumn", "insertitem", "move", "pointerx", "pointery", "postevent", "print", "resize", "selectedindex", "setcolumn", "setfocus", "setitem", "setoverlaypicture", "setposition", "setredraw", "show", "sort", "totalcolumns", "totalitems", "totalselected", "triggerevent", "typeof"}),
    "menu": frozenset({"check", "classname", "disable", "enable", "getcontextservice", "getparent", "hide", "popmenu", "postevent", "show", "triggerevent", "typeof", "uncheck"}),
    "monthcalendar": frozenset({"classname", "clearbolddates", "drag", "getcontextservice", "getdatelimits", "getdisplayrange", "getparent", "getselecteddate", "getselectedrange", "gettoday", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setbolddate", "setdatelimits", "setfocus", "setposition", "setredraw", "setselecteddate", "setselectedrange", "settoday", "show", "triggerevent", "typeof"}),
    "multilineedit": frozenset({"canundo", "classname", "clear", "copy", "cut", "drag", "getcontextservice", "getparent", "hide", "linecount", "linelength", "move", "paste", "pointerx", "pointery", "position", "postevent", "print", "replacetext", "resize", "scroll", "selectedlength", "selectedline", "selectedstart", "selectedtext", "selecttext", "setfocus", "setposition", "setredraw", "show", "textline", "triggerevent", "typeof", "undo"}),
    "oval": frozenset({"classname", "getcontextservice", "getparent", "hide", "move", "postevent", "resize", "show", "triggerevent", "typeof"}),
    "picture": frozenset({"classname", "drag", "draw", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setpicture", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "picturebutton": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "picturehyperlink": frozenset({"classname", "drag", "draw", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setpicture", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "picturelistbox": frozenset({"additem", "addpicture", "classname", "deleteitem", "deletepicture", "deletepictures", "dirlist", "dirselect", "drag", "finditem", "getcontextservice", "getparent", "hide", "insertitem", "move", "pointerx", "pointery", "postevent", "print", "reset", "resize", "selectedindex", "selecteditem", "selectitem", "setfocus", "setposition", "setredraw", "setstate", "settop", "show", "state", "text", "top", "totalitems", "totalselected", "triggerevent", "typeof"}),
    "radiobutton": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "rectangle": frozenset({"classname", "getcontextservice", "getparent", "hide", "move", "postevent", "resize", "show", "triggerevent", "typeof"}),
    "ribbonbar": frozenset({"classname", "deletecategory", "deletecheckbox", "deletecombobox", "deletegroup", "deleteitem", "deletelargebutton", "deletepanel", "deletesmallbutton", "deletetabbutton", "drag", "exportjson", "exporttojsonfile", "exporttoxmlfile", "exportxml", "getactivecategory", "getapplicationbutton", "getbestheight", "getcategory", "getcategorybyindex", "getcategorycount", "getcategoryindex", "getcheckbox", "getchilditembyindex", "getchilditemcount", "getcombobox", "getcontextservice", "getgroup", "getitem", "getitembytag", "getitemparent", "getlargebutton", "getmenubybuttonhandle", "getpanel", "getparent", "getsmallbutton", "gettabbutton", "gettabbuttonbyindex", "gettabbuttoncount", "hide", "importfromjsonfile", "importfromxmlfile", "importjson", "importxml", "insertcategory", "insertcategoryfirst", "insertcategorylast", "insertcheckbox", "insertcheckboxfirst", "insertcheckboxlast", "insertcombobox", "insertcomboboxfirst", "insertcomboboxlast", "insertgroup", "insertgroupfirst", "insertgrouplast", "insertlargebutton", "insertlargebuttonfirst", "insertlargebuttonlast", "insertpanel", "insertpanelfirst", "insertpanellast", "insertsmallbutton", "insertsmallbuttonfirst", "insertsmallbuttonlast", "inserttabbutton", "inserttabbuttonfirst", "inserttabbuttonlast", "isminimized", "move", "pointerx", "pointery", "postevent", "print", "removeapplicationbutton", "replacecategorybyjson", "replacecategorybyxml", "resize", "setactivecategory", "setactivecategorybyindex", "setapplicationbutton", "setcategory", "setcheckbox", "setcombobox", "setfocus", "setgroup", "setitem", "setlargebutton", "setminimized", "setpanel", "setposition", "setredraw", "setsmallbutton", "settabbutton", "show", "triggerevent", "typeof"}),
    "richtextedit": frozenset({"canredo", "canundo", "classname", "clear", "clearall", "copy", "copyrtf", "cut", "datasource", "drag", "find", "findnext", "formcheckboxgetchecked", "formcheckboxinsert", "formcheckboxsetchecked", "formcomboboxgetitems", "formcomboboxinsert", "formcomboboxsetitems", "formdatefieldgetdate", "formdatefieldgetformat", "formdatefieldinsert", "formdatefieldsetdate", "formdatefieldsetformat", "formfielddelete", "formfieldgetcurrent", "formfieldgetdeletable", "formfieldgetemptywidth", "formfieldgetend", "formfieldgetstart", "formfieldgettext", "formfieldnext", "formfieldsetcurrent", "formfieldsetdeletable", "formfieldsetemptywidth", "formfieldsettext", "formtextfieldinsert", "getalignment", "getcontextservice", "getparagraphsetting", "getparent", "getspacing", "gettextcolor", "gettextfontname", "gettextfontsize", "gettextstyle", "hide", "inputfieldchangedata", "inputfieldcurrentname", "inputfielddeletecurrent", "inputfieldgetdata", "inputfieldinsert", "inputfieldlocate", "insertdocument", "insertpicture", "ispreview", "linecount", "linelength", "move", "pagecount", "paste", "pastertf", "pastespecial", "pointerx", "pointery", "position", "postevent", "preview", "print", "printex", "redo", "removetab", "replacetext", "resize", "savedocument", "savedocumentaspdf", "scroll", "scrollnextpage", "scrollnextrow", "scrollpriorpage", "scrollpriorrow", "scrolltorow", "selectedcolumn", "selectedlength", "selectedline", "selectedpage", "selectedstart", "selectedtext", "selecttext", "selecttextall", "selecttextline", "selecttextword", "setalignment", "setfocus", "setparagraphsetting", "setposition", "setredraw", "setspacing", "settab", "settextcolor", "settextfontname", "settextfontsize", "settextstyle", "show", "showheadfoot", "tableatinputpos", "tablecanchangeattr", "tablecellselect", "tablecellstart", "tablecolumnatinputpos", "tabledelete", "tabledeletecolumn", "tabledeletecolumns", "tabledeleterow", "tabledeleterows", "tablefromselection", "tablegetcellbackcolor", "tablegetcellbordercolor", "tablegetcellborderwidth", "tablegetcellheader", "tablegetcellheight", "tablegetcellhorizontalext", "tablegetcellhorizontalpos", "tablegetcelllength", "tablegetcellnumberformat", "tablegetcelltext", "tablegetcelltextgap", "tablegetcelltexttype", "tablegetcellvertalign", "tablegetcolumncount", "tablegetrowcount", "tableinsert", "tableinsertcolumn", "tableinsertdialog", "tableinsertrow", "tableinsertrows", "tablemergecells", "tablenext", "tablepropertiesdialog", "tablerowatinputpos", "tablesetcellbackcolor", "tablesetcellbordercolor", "tablesetcellborderwidth", "tablesetcellheader", "tablesetcellheight", "tablesetcellhorizontalext", "tablesetcellhorizontalpos", "tablesetcellnumberformat", "tablesetcelltext", "tablesetcelltextgap", "tablesetcelltexttype", "tablesetcellvertalign", "tablesplitcells", "targetdelete", "targetgetname", "targetgoto", "targetinsert", "targetnext", "targetsetname", "textfieldgettext", "textfieldgettype", "textfieldgettypedata", "textfieldinsert", "textfieldsettext", "textfieldsettypeanddata", "textframegetbackcolor", "textframegetborderwidth", "textframegetinternalmargin", "textframegetmarkerlines", "textframegettext", "textframeinsert", "textframeinsertaschar", "textframeinsertfixed", "textframeselect", "textframesetbackcolor", "textframesetborderwidth", "textframesetinternalmargin", "textframesetmarkerlines", "textframesettext", "textline", "triggerevent", "typeof", "undo"}),
    "roundrectangle": frozenset({"classname", "getcontextservice", "getparent", "hide", "move", "resize", "show", "typeof"}),
    "singlelineedit": frozenset({"canundo", "classname", "clear", "copy", "cut", "drag", "getcontextservice", "getparent", "hide", "move", "paste", "pointerx", "pointery", "position", "postevent", "print", "replacetext", "resize", "selectedlength", "selectedstart", "selectedtext", "selecttext", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof", "undo"}),
    "statichyperlink": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "statictext": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "tab": frozenset({"classname", "closetab", "drag", "getcontextservice", "getparent", "hide", "move", "movetab", "opentab", "opentabwithparm", "pointerx", "pointery", "postevent", "print", "resize", "selecttab", "setfocus", "setposition", "setredraw", "show", "tabpostevent", "tabtriggerevent", "triggerevent", "typeof"}),
    "transaction": frozenset({"classname", "dbhandle", "enablesecureconnection", "getcontextservice", "getparent", "getsecureconnectionstring", "postevent", "setsecureconnectionproperty", "setsecureconnectionstring", "syntaxfromsql", "triggerevent", "typeof"}),
    "treeview": frozenset({"addpicture", "addstatepicture", "classname", "collapseitem", "deleteitem", "deletepicture", "deletepictures", "deletestatepicture", "deletestatepictures", "drag", "editlabel", "expandall", "expanditem", "finditem", "getcontextservice", "getitem", "getitematpointer", "getparent", "hide", "insertitem", "insertitemfirst", "insertitemlast", "insertitemsort", "move", "pointerx", "pointery", "postevent", "print", "resize", "selectitem", "setdrophighlight", "setfirstvisible", "setfocus", "setitem", "setlevelpictures", "setoverlaypicture", "setposition", "setredraw", "show", "sort", "sortall", "triggerevent", "typeof"}),
    "vprogressbar": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "offsetpos", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setrange", "setredraw", "show", "stepit", "triggerevent", "typeof"}),
    "vscrollbar": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "vtrackbar": frozenset({"classname", "drag", "getcontextservice", "getparent", "hide", "move", "pointerx", "pointery", "postevent", "print", "resize", "selectionrange", "setfocus", "setposition", "setredraw", "show", "triggerevent", "typeof"}),
    "webbrowser": frozenset({"canceldownload", "classname", "clearbrowsingdata", "closedefaultdownloaddialog", "drag", "evaluatejavascriptasync", "evaluatejavascriptsync", "getcontextservice", "getparent", "getsource", "goback", "goforward", "hide", "move", "navigate", "navigatetostring", "opendefaultdownloaddialog", "pausedownload", "pointerx", "pointery", "postevent", "postjsonwebmessage", "poststringwebmessage", "print", "printaspdf", "refresh", "registerevent", "resize", "resumedownload", "setfocus", "setposition", "setredraw", "show", "stopnavigation", "triggerevent", "typeof", "unregisterevent", "zoom"}),
    "window": frozenset({"arrangesheets", "changemenu", "classname", "closechannel", "closeuserobject", "commitdocking", "execremote", "getactivesheet", "getcommanddde", "getcommandddeorigin", "getcontextservice", "getdatadde", "getdataddeorigin", "getfirstsheet", "getnextsheet", "getparent", "getremote", "gettoolbar", "gettoolbarpos", "hide", "ismaximizealltabbedsheetsenabled", "istabbedviewenabled", "loaddockingstate", "move", "openchannel", "opensheet", "opensheetasdocument", "opensheetdocked", "opensheetfromdockingstate", "opensheetintabgroup", "opensheetwithparm", "opensheetwithparmasdocument", "opensheetwithparmdocked", "opensheetwithparmfromdockingstate", "opensheetwithparmintabgroup", "openuserobject", "openuserobjectwithparm", "parentwindow", "pointerx", "pointery", "postevent", "print", "resize", "respondremote", "savedockingstate", "setdatadde", "setfocus", "setmicrohelp", "setposition", "setredraw", "setremote", "setsheetid", "settoolbar", "settoolbarpos", "show", "starthotlink", "startserverdde", "stophotlink", "stopserverdde", "triggerevent", "typeof", "workspaceheight", "workspacewidth", "workspacex", "workspacey"}),
}


# Unified lookup: free functions are globally callable, class methods need
# receiver-type tracing. For now, PB_BUILTIN_CALLS remains the fast-path
# for free-function detection. Class methods are resolved in resolve_calls
# when receiver type is available (future: receiver-type tracing).
PB_BUILTIN_FREES = PB_BUILTIN_CALLS


def parse_params(params_text: str) -> list[tuple[str, str]]:
    """Parse ``"ref datawindow adw , long row"`` into ``[("adw", "datawindow"), ...]``."""
    if not params_text or not params_text.strip():
        return []
    result: list[tuple[str, str]] = []
    for segment in params_text.split(","):
        segment = segment.strip()
        if not segment:
            continue
        parts = segment.rsplit(None, 1)
        if len(parts) == 2:
            _mods_type, name = parts
            type_words = _mods_type.split()
            if type_words:
                ptype = type_words[-1]
                result.append((name, ptype))
    return result


def classify_type(
    var_type: str,
    objects: set[str],
    user_types: set[str],
) -> tuple[str, str | None]:
    """Return ``(resolved_kind, resolved_target)`` for a declared type string."""
    lower = var_type.lower()
    if lower in PRIMITIVES:
        return ("primitive", None)
    if lower == "any":
        return ("any", None)
    if var_type in objects:
        return ("object", var_type)
    if var_type in user_types:
        return ("user_type", var_type)
    if lower in PB_BUILTINS:
        return ("primitive", None)
    return ("unresolved", None)


def _extract_line(body: list | str, callee_name: str, call_type: str) -> int | None:
    """Walk body_json to find source line for a specific call."""
    if isinstance(body, str):
        body = json.loads(body) if body else []
    for tag, node, line in walk_tagged(body):
        if tag == call_type:
            if call_type == "ExCall":
                segs = node.get("callee", {}).get("segments", [])
                if segs:
                    full_name = ".".join(s.get("name", "") for s in segs)
                    if full_name == callee_name:
                        return line
            elif call_type == "ExMethodCall":
                if node.get("method", "") == callee_name:
                    return line
        elif tag == "ExDispatch":
            name = node.get("contents", {}).get("name", "") or node.get("name", "")
            if name == callee_name:
                return line
    return None


def _build_ancestors(
    obj_name: str,
    inherits: dict[str, str],
) -> list[str]:
    """Walk inherits chain from obj_name upward. Returns [obj_name, parent, grandparent, ...]."""
    chain = [obj_name]
    current = obj_name
    visited = {current}
    while current in inherits:
        parent = inherits[current]
        if parent in visited:
            break
        visited.add(parent)
        chain.append(parent)
        current = parent
    return chain


def _resolve_virtual(
    to_name: str,
    obj_name: str,
    proc_map: dict[str, set[str]],
    inherits: dict[str, str],
    global_procs: set[str],
) -> tuple[str | None, str | None, str, str]:
    """Resolve a simple (non-dotted) call via own procedures + ancestor chain + globals.

    Returns (target_object, target_proc, resolution_kind, confidence).
    """
    chain = _build_ancestors(obj_name, inherits)
    found_in: list[str] = []
    for ancestor in chain:
        if to_name in proc_map.get(ancestor, set()):
            found_in.append(ancestor)
    if len(found_in) == 1:
        kind = "inherited" if found_in[0] != obj_name else "virtual"
        return (found_in[0], to_name, kind, "high")
    if len(found_in) > 1:
        return (None, None, "virtual", "medium")
    if to_name in global_procs:
        for obj, procs in proc_map.items():
            if to_name in procs:
                return (obj, to_name, "virtual", "high")
    return (None, None, "unresolved", "low")


def resolve_types(
    local_vars: list[LocalVarRow],
    procedures: list[ProcedureRow],
    objects: set[str],
    user_types: set[str],
) -> list[ResolvedTypeRow]:
    """Build resolved_types from local_variables + parsed procedure params."""
    results: list[ResolvedTypeRow] = []
    for row in local_vars:
        kind, target = classify_type(row.var_type, objects, user_types)
        results.append(ResolvedTypeRow(
            file=row.file, object=row.object, proc_name=row.proc_name,
            var_name=row.var_name, raw_type=row.var_type,
            resolved_kind=kind, resolved_target=target,
            is_parameter=False, scope_line=row.start_line,
        ))

    for proc in procedures:
        if not proc.params:
            continue
        parsed = parse_params(proc.params)
        for name, ptype in parsed:
            kind, target = classify_type(ptype, objects, user_types)
            results.append(ResolvedTypeRow(
                file=proc.file, object=proc.object, proc_name=proc.name,
                var_name=name, raw_type=ptype,
                resolved_kind=kind, resolved_target=target,
                is_parameter=True, scope_line=proc.start_line,
            ))

    return results


def resolve_calls(
    calls: list[CallRow],
    procedures: list[ProcedureRow],
    inherits_rows: list[tuple[str, str]],
    all_objects: set[str] | None = None,
    var_types: dict[tuple[str, str, str], str] | None = None,
) -> list[ResolvedCallRow]:
    """Build resolved_calls from calls + body_json line extraction + resolution.

    var_types maps (object, proc_name, var_name) → resolved type name,
    used to resolve bare calls as methods on typed local variables.
    """
    inherits = dict(inherits_rows)
    proc_map: dict[str, set[str]] = {}
    proc_by_key: dict[tuple[str, str], ProcedureRow] = {}
    for proc in procedures:
        proc_map.setdefault(proc.object, set()).add(proc.name)
        proc_by_key[(proc.object, proc.name)] = proc

    global_procs: set[str] = set()
    for obj, procs in proc_map.items():
        for p in procs:
            global_procs.add(p)

    obj_set = all_objects if all_objects is not None else {proc.object for proc in procedures}

    # Build object → ancestor chain for PB class method resolution
    obj_ancestors: dict[str, list[str]] = {}
    for child, parent in inherits_rows:
        chain = [child]
        cur = child
        visited = {cur}
        while cur in inherits:
            p = inherits[cur]
            if p in visited:
                break
            visited.add(p)
            chain.append(p)
            cur = p
        obj_ancestors[child] = chain[1:]  # exclude self

    results: list[ResolvedCallRow] = []
    for row in calls:
        call_line: int | None = None
        target_object: str | None = None
        target_proc: str | None = None
        resolution_kind = "unresolved"
        confidence = "low"

        proc_row = proc_by_key.get((row.object, row.from_proc))
        if proc_row and proc_row.body_json:
            call_line = _extract_line(proc_row.body_json, row.to_name, row.call_type)

        if row.call_type == "ExCall":
            to = row.to_name
            if "." in to:
                parts = to.rsplit(".", 1)
                first, last = parts[0], parts[1]
                if first in obj_set:
                    target_object = first
                    if last in proc_map.get(first, set()):
                        target_proc = last
                        resolution_kind = "static"
                        confidence = "high"
                    else:
                        resolution_kind = "static"
                        confidence = "medium"
                elif last.lower() in PB_BUILTIN_CALLS:
                    resolution_kind = "builtin"
                    confidence = "high"
                else:
                    resolution_kind = "unresolved"
                    confidence = "low"
            else:
                if to.lower() in PB_BUILTIN_CALLS:
                    resolution_kind = "builtin"
                    confidence = "high"
                else:
                    target_object, target_proc, resolution_kind, confidence = _resolve_virtual(
                        to, row.object, proc_map, inherits, global_procs,
                    )
                    # PB class method fallback: check if method exists on
                    # caller's type or its ancestors via PB_CLASS_METHODS
                    if resolution_kind == "unresolved":
                        for ancestor in [row.object, *obj_ancestors.get(row.object, [])]:
                            methods = PB_CLASS_METHODS.get(ancestor.lower(), frozenset())
                            if to.lower() in methods:
                                resolution_kind = "builtin"
                                confidence = "high"
                                break
                    # Local variable type fallback: check if method exists
                    # on any typed local variable in the current procedure.
                    # Walk the type's own inheritance chain for user types.
                    if resolution_kind == "unresolved" and var_types:
                        for (obj, proc, vname), vtype in var_types.items():
                            if obj == row.object and (proc == row.from_proc or proc == ""):
                                # Check the type itself and its ancestors
                                type_chain = [vtype.lower()]
                                cur = vtype
                                visited = {cur}
                                while cur in inherits:
                                    p = inherits[cur]
                                    if p in visited:
                                        break
                                    visited.add(p)
                                    type_chain.append(p.lower())
                                    cur = p
                                for tc in type_chain:
                                    methods = PB_CLASS_METHODS.get(tc, frozenset())
                                    if to.lower() in methods:
                                        resolution_kind = "builtin"
                                        confidence = "medium"
                                        break
                            if resolution_kind != "unresolved":
                                break
        elif row.call_type == "ExMethodCall":
            if row.to_name.lower() in PB_BUILTIN_CALLS:
                resolution_kind = "builtin"
                confidence = "high"
            else:
                resolution_kind = "unresolved"
                confidence = "low"
        elif row.call_type == "ExDispatch":
            resolution_kind = "unresolved"
            confidence = "low"

        results.append(ResolvedCallRow(
            file=row.file, object=row.object, from_proc=row.from_proc,
            to_name=row.to_name, call_type=row.call_type,
            call_line=call_line,
            target_object=target_object, target_proc=target_proc,
            resolution_kind=resolution_kind, confidence=confidence,
        ))

    return results


def extract_global_vars(
    global_vars_blocks: list[GlobalVarRow],
    global_instances: list[dict],
) -> list[GlobalVarRow]:
    """Return global variable rows (already extracted by importing)."""
    return global_vars_blocks
