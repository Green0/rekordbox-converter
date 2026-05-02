# Parses the PLAYLISTS section of a Rekordbox XML database.
# Playlists are nested inside NODE elements: Type="0" is a folder, Type="1" is a playlist.
# Playlist tracks use <TRACK Key="N"/> where Key matches TrackID in the COLLECTION.

function Get-RekordboxPlaylists([xml]$db) {
    $results  = [System.Collections.Generic.List[hashtable]]::new()
    $rootNode = $db.SelectSingleNode("//PLAYLISTS/NODE")
    if ($rootNode) { Collect-Playlists $rootNode "" $results }
    return $results.ToArray()
}

function Collect-Playlists($node, [string]$parentPath, $list) {
    foreach ($child in $node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }

        $type = $child.GetAttribute("Type")
        $name = $child.GetAttribute("Name")
        $path = if ($parentPath) { "$parentPath / $name" } else { $name }

        if ($type -eq "1") {
            $ids = @($child.SelectNodes("TRACK") | ForEach-Object { $_.GetAttribute("Key") })
            $list.Add(@{ DisplayName = $path; TrackIds = $ids })
        } elseif ($type -eq "0") {
            Collect-Playlists $child $path $list
        }
    }
}
