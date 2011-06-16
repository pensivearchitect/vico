# Terminal usage

Vico includes a command line tool that can be used to launch vico from
the shell.

To use the tool from the command line, create a link from the
application bundle to a directory in your PATH. If you have a
<kbd>bin</kbd> directory in your home directory, create it as:

<code>
ln -s /Applications/Vico.app/Contents/MacOS/vicotool ~/bin/vico
</code>

If you want to install it for all users on the machine, create the link
in a global directory (this requires administrator privileges):

<code>
sudo ln -s /Applications/Vico.app/Contents/MacOS/vicotool /usr/local/bin/vico
</code>

If Vico is not stored in your /Applications folder, adjust the command
appropriately. Once the link is created, it will be kept up-to-date
when Vico is updated.

To open a file with Vico from the shell, simply type:

<code>
vico filename
</code>

You can open multiple files at once, also using globbing characters (eg,
<kbd>vico *.py</kbd>). If you specify a directory, Vico will display a
new window with the directory selected in the explorer sidebar.

To see a quick description of the command line usage, use the
<kbd>-h</kbd> option:

<code>
$ vico -h
syntax: vicotool [-hrw] [-e string] [-f file] [-p params] [file ...]
options:
    -h            show this help
    -e string     evaluate the string as a Nu script
    -f file       read file and evaluate as a Nu script
    -p params     read script parameters as a JSON string
    -p -          read script parameters as JSON from standard input
    -r            enter runloop (don't exit script immediately)
    -w            wait for document to close
</code>

