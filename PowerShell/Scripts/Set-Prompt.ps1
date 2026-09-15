Function prompt
{
	# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	#                                                                              Rikard Ronnkvist / snowland.se
	# Multicolored prompt with marker for windows started as Admin and marker for providers outside filesystem
	# Examples
	#    C:\Windows\System32>
	#    [Admin] C:\Windows\System32>
	#    [Registry] HKLM:\SOFTWARE\Microsoft\Windows>
	#    [Admin] [Registry] HKLM:\SOFTWARE\Microsoft\Windows>
	# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

	# New nice WindowTitle
	$Host.UI.RawUI.WindowTitle = "PowerShell v" + (get-host).Version.Major + "." + (get-host).Version.Minor + " (" + $pwd.Provider.Name + ") " + $pwd.Path

	# Start with PS
	Write-Host "PS " -NoNewLine -foregroundcolor Blue

	# Write user to prompt
	Write-Host "[" -NoNewLine -foregroundcolor DarkGray
	Write-Host $env:username -NoNewLine -foregroundcolor Green
	Write-Host "]" -NoNewLine -foregroundcolor DarkGray

	# Admin ?
	if((New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
	{
		# Admin-mark in WindowTitle
		$Host.UI.RawUI.WindowTitle = "[Admin] " + $Host.UI.RawUI.WindowTitle

		# Set background color, unless running PowerShellISE
		If (-not (Test-Path variable:global:psISE))
		{
			# $Host.UI.RawUI.BackgroundColor = "DarkRed"
		}
		

		# Admin-mark on prompt
		Write-Host "[" -NoNewLine -foregroundcolor DarkGray
		Write-Host "Admin" -NoNewLine -foregroundcolor Red
		Write-Host "]" -NoNewLine -foregroundcolor DarkGray
	} Else
	{
		# Set-PSReadlineOption -ResetTokenColors
	}

	# Show providername if you are outside FileSystem
	if ($pwd.Provider.Name -ne "FileSystem") {
		Write-Host "[" -NoNewLine -foregroundcolor DarkGray
		Write-Host $pwd.Provider.Name -NoNewLine -foregroundcolor Gray
		Write-Host "]" -NoNewLine -foregroundcolor DarkGray
	}

	Write-Host " $( Split-Path $pwd -Leaf )" -NoNewLine -foregroundcolor Yellow
	Write-Host ">" -NoNewLine -foregroundcolor Gray
	return " "
} # End Function Prompt