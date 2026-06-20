// mathparser.h : main header file for the MATHPARSER DLL
//

#if !defined(AFX_MATHPARSER_H__E1884E33_9086_421F_8C23_19AA63AF84A4__INCLUDED_)
#define AFX_MATHPARSER_H__E1884E33_9086_421F_8C23_19AA63AF84A4__INCLUDED_

#if _MSC_VER > 1000
#pragma once
#endif // _MSC_VER > 1000

#ifndef __AFXWIN_H__
	#error include 'stdafx.h' before including this file for PCH
#endif

#include "resource.h"		// main symbols

/////////////////////////////////////////////////////////////////////////////
// CMathparserApp
// See mathparser.cpp for the implementation of this class
//

class CMathparserApp : public CWinApp
{
public:
	CMathparserApp();

// Overrides
	// ClassWizard generated virtual function overrides
	//{{AFX_VIRTUAL(CMathparserApp)
	//}}AFX_VIRTUAL

	//{{AFX_MSG(CMathparserApp)
		// NOTE - the ClassWizard will add and remove member functions here.
		//    DO NOT EDIT what you see in these blocks of generated code !
	//}}AFX_MSG
	DECLARE_MESSAGE_MAP()
};


/////////////////////////////////////////////////////////////////////////////

//{{AFX_INSERT_LOCATION}}
// Microsoft Visual C++ will insert additional declarations immediately before the previous line.

#endif // !defined(AFX_MATHPARSER_H__E1884E33_9086_421F_8C23_19AA63AF84A4__INCLUDED_)
