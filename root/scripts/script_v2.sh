#!/usr/bin/env bash
scriptVersion="2"

######### DEBUGGING
#raUsername=
#raWebApiKey=
libraryPath="/roms"
consoles="gb,nes,snes,mastersystem,sega32x,psx"

######### LOGGING

# auto-clean up log file to reduce space usage
if [ -f "/config/log.txt" ]; then
  find /config -type f -iname "log.txt" -size +1024k -delete
fi

touch "/config/log.txt"
exec &> >(tee -a "/config/log.txt")

######### FUNCTIONS

Log () {
  m_time=`date "+%F %T"`
  echo $m_time" :: RA-Rom-Processor :: $scriptVersion :: $consoleName ($consoleFolder) :: $currentsubprocessid of $totalCount :: "$1
}

DownloadFile () {
  # $1 = URL
  # $2 = Output Folder/file
  # $3 = Number of concurrent connections to use
  # $4 = fileName
  Log "Downloading :: $4"
  wget "$1" -O "$2"
  sleep 1
  if [ ! -f "$2" ]; then
    Log "Download Failed :: $1"
  fi
  if [ -f "$2" ]; then
    chmod 666 "$2"
  fi
}

DownloadFileVerification () {
  case "$1" in
    *.zip|*.ZIP)
      verify="$(unzip -t "$1" &>/dev/null; echo $?)"
      ;;
    *.rar|*.RAR)
      verify="$(unrar t "$1" &>/dev/null; echo $?)"
      ;;
    *.7z|*.7Z)
      verify="$(7z t "$1" &>/dev/null; echo $?)"
      ;;
    *.chd|*.CHD)
      verify="$(chdman verify -i "$1" &>/dev/null; echo $?)"
      ;;
    *.iso|*.ISO)
      verify="0"
      ;;
  esac
  
  if [ "$verify" != "0" ]; then
    Log "$1 :: ERROR :: Failed Verification!"
    rm "$1"
  else
    Log "$1 :: Download Verified!"
  fi
}

UncompressFile () {
  # $1 is input file
  # $2 is output folder
  Log "Uncompressing \"$1\" to \"$2\""
  case "$1" in
    *.zip|*.ZIP)
      Log "Zip file detected!"
      unzip -o -d "$2" "$1" >/dev/null
      ;;
    *.rar|*.RAR)
      Log "Rar file detected!"
      unrar x "$1" "$2" &>/dev/null
      ;;
    *.7z|*.7Z)
      Log "7z file detected!"
      7z x "$1" "$2" &>/dev/null
      ;;
  esac
  Log "Uncompressing Complete!"
  rm "$1"
}

CompressFile () {
  # $1 is input file
  # $2 is output file
  Log "Compress \"$1\" to \"$2\""
  zip -mj "$2" "$1" >/dev/null  
  Log "Compressing Complete!"
}

RaHashRom (){
  # $1 = ROM file
  # $2 = Console ID
  raHash=""
  Log "$1 :: Hashing..."
	raHash=$(/usr/local/RALibretro/bin64/RAHasher $2 "$1") || ret=1
  Log "$1 :: Hash Found :: $raHash"
}

DownloadRaHashLibrary () {
  # $1 = raConsoleId
  # $2 = consoleFolder

  # create hash library folder
  if [ ! -d /config/ra_hash_libraries ]; then
    mkdir -p /config/ra_hash_libraries
    chmod 777 /config/ra_hash_libraries    
  fi
  Log "Getting the console hash library from RetroAchievements.org..."
  if [ ! -f "/config/ra_hash_libraries/${2}_hashes.json" ]; then
    curl -s "https://retroachievements.org/dorequest.php?r=hashlibrary&c=$1" | jq '.' > "/config/ra_hash_libraries/${2}_hashes.json"
    chmod 666 "/config/ra_hash_libraries/${2}_hashes.json"
  fi
  Log "Done"
}

RomRaHashVerification () {
  # $1 = romFile
  # $2 = consoleFolder
  raGameId=""
  Log "$1 :: Matching To RetroAchievements.org DB"
  if cat "/config/ra_hash_libraries/${2}_hashes.json" | jq -r .[] | grep -i "\"$raHash\"" | read; then
    raGameId=$(cat "/config/ra_hash_libraries/${2}_hashes.json" | jq -r .[] | grep -i "\"$raHash\"" | cut -d ":" -f 2 | sed "s/\ //g" | sed "s/,//g")
    Log "$1 :: Match Found :: Game ID :: $raGameId"
  else
    Log "$1 :: ERROR :: Not Found on RetroAchievements.org DB"
    rm "$1"
  fi
}

MoveRomToFinalLocation () {
  # $1 = romFile
  # $2 = Destination
  if [ ! -d "$2" ]; then
    Log "Creating $2"
    mkdir -p "$2"
    chmod 777 "$2"
    Log "Done"
  fi
  outputFile=""
  outputFile="$2/$(basename "$romFile")"
  if [ ! -f "$outputFile" ]; then
    Log "$1 :: Moving file to: $outputFile"
    mv "$1" "$outputFile"
    chmod 666 "$outputFile"
    Log "Done"
  fi
}


UrlDecode () { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

######### PROCESS

if [ ! -d /config/consoles ]; then
  mkdir -p /config/consoles
  chmod 777 /config/consoles
fi

IFS=',' read -r -a filters <<< "$consoles"
for console in "${filters[@]}"
do

  consoleFile=/config/consoles/$console.sh
  if [ ! -f $consoleFile ]; then
    consoleFile=/consoles/$console.sh
  fi

  if [ ! $consoleFile ]; then
    Log "ERROR :: Console Data File ($consoleFile) Missing..."
    continue
  fi
  source $consoleFile

  if [ -z "$raUsername" ] || [ -z "$raWebApiKey" ]; then
    Log "ERROR :: raUsername & raWebApiKey not set, exiting..."
    exit
  fi
  
  raGameList="$(wget -qO- "https://retroachievements.org/API/API_GetGameList.php?z=${raUsername}&y=${raWebApiKey}&i=$raConsoleId")"
  raGameTitles=$(echo "$raGameList" | jq -r .[].Title)
  if [ -d $libraryPath/temp ]; then
    rm -rf $libraryPath/temp
  fi

  if [ ! -d $libraryPath/temp ]; then
    mkdir -p $libraryPath/temp
  fi

  totalCount="$(echo "$archiveUrl" | wc -l)"
  OLDIFS="$IFS"
  IFS=$'\n'
  archiveUrls=($(echo "$archiveUrl"))
  IFS="$OLDIFS"
  for Url in ${!archiveUrls[@]}; do
    currentsubprocessid=$(( $Url + 1 ))
    downloadUrl="${archiveUrls[$Url]}"
    decodedUrl="$(UrlDecode "$downloadUrl")"
    fileName="$(basename "$decodedUrl")"
    fileNameNoExt="${fileName%.*}"
    fileNameSearch=$(echo "$fileNameNoExt"| cut -f1 -d"(" | sed "s/\ $//g" )
    if echo "$raGameTitles" | grep -i "$fileNameSearch" | read; then
      Log "$fileNameNoExt :: Title found on RA Game List"
    else
      Log "$fileNameNoExt :: title not found on RA Game List, skipping..."
      continue
    fi
    
    if [ -f "/config/logs/$consoleFolder/$fileName.txt" ]; then
      Log "Previously Processed..."
      continue
    fi
    if [ -f "$libraryPath/$consoleFolder/$fileNameNoExt.zip" ]; then
      Log "$libraryPath/$consoleFolder/$fileNameNoExt.zip :: File already exists :: skipping..."
      mkdir -p /config/logs/$consoleFolder
      touch "/config/logs/$consoleFolder/$fileName.txt"
      continue
    fi
    DownloadFile "$downloadUrl" "$libraryPath/temp/$fileName" "$concurrentDownloadThreads" "$fileName"

    if [ ! -f "$libraryPath/temp/$fileName" ]; then
      Log "Skipping..."
      continue
    else
      mkdir -p $libraryPath/logs/$consoleFolder
      touch "$libraryPath/logs/$consoleFolder/$fileName.txt"
    fi
    DownloadFileVerification "$libraryPath/temp/$fileName"
    if [ ! -f "$libraryPath/temp/$fileName" ]; then
      Log "Skipping..."
      continue
    fi
    if [ "$uncompressRom" == "true" ]; then
      UncompressFile "$libraryPath/temp/$fileName" "$libraryPath/temp"
    fi
    romFile=$(find $libraryPath/temp -type f)
    romFileExt="${romFile##*.}"
    Log "Checking for Valid ROM extension"
    if ! echo "$consoleRomFileExt" | grep -E ".$romFileExt(,|$)" | read; then
      Log "ERROR :: \"$consoleRomFileExt\" file extension(s) expected :: \"$romFileExt\" found..."
      Log "Skipping..."
      rm $libraryPath/temp/*
      continue
    else
      Log "Valid ROM extension found (.$romFileExt)"
    fi

    RaHashRom "$romFile" "$raConsoleId"
    DownloadRaHashLibrary "$raConsoleId" "$consoleFolder"
    RomRaHashVerification "$romFile" "$consoleFolder"
    if [ ! -f "$romFile" ]; then
      Log "Skipping..."
      continue
    fi
    if [ "$compressRom" == "true" ]; then
      CompressFile "$romFile" "$libraryPath/temp/$fileNameNoExt.zip"
    fi
    romFile=$(find $libraryPath/temp -type f)
    MoveRomToFinalLocation "$romFile" "$libraryPath/$consoleFolder"
    
    if [ -d $libraryPath/temp ]; then
      rm $libraryPath/temp/* &>/dev/null
    fi
    
  done

  if [ -d $libraryPath/temp ]; then
    rm -rf $libraryPath/temp
  fi

done

exit
