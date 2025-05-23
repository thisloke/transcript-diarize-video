# Transcription Runner con Multi-Chunk Processing e GPU Parallela

Questo pacchetto ti consente di:
- Creare un'istanza EC2 GPU su AWS (g4dn.12xlarge)
- Suddividere e trascrivere un file video `.mp4` in più chunk
- Generare automaticamente transcript + speaker diarization
- Scaricare i file di output
- Terminare l'istanza per risparmiare costi
- Applicare spostamento temporale ai timestamp delle trascrizioni
- Configurare facilmente le opzioni tramite file `.env`

---

## ✅ Prerequisiti

### 1. **Installare AWS CLI**
Se non hai ancora installato AWS CLI:
- Su macOS con Homebrew:
```bash
brew install awscli
```
- Su Linux (Debian/Ubuntu):
```bash
sudo apt update
sudo apt install awscli
```

### 2. **Configurare AWS CLI**
Una volta installato, esegui:
```bash
aws configure
```
Inserisci:
- Access key ID
- Secret access key
- Regione predefinita (es: `eu-south-1`)
- Formato output: `json`

### 3. **Creare una chiave SSH per EC2**
Nel terminale, esegui:
```bash
aws ec2 create-key-pair --key-name whisper-key --query 'KeyMaterial' --output text > ~/.ssh/whisper-key.pem
chmod 400 ~/.ssh/whisper-key.pem
```

### 4. **Installa netcat**
- Su macOS con Homebrew:
```bash
brew install netcat
```
- Su Linux (Debian/Ubuntu):
```bash
sudo apt install netcat
```

### 5. **Registrarsi su Hugging Face e ottenere token**
Vai su: https://huggingface.co/settings/tokens
Crea un token con accesso ai modelli (read access) e copia il valore.

### 6. **IAM role "WhisperS3Profile" con accesso S3**
Assicurati che il tuo account AWS abbia un ruolo IAM chiamato "WhisperS3Profile" con permessi di accesso S3.

### 7. **Configurare il file .env**
Copia il file `.env.sample` in `.env` e modifica i valori secondo le tue esigenze:
```bash
cp .env.sample .env
nano .env  # o usa l'editor che preferisci
```

---

## ▶️ Come usare

### Metodo Base
```bash
chmod +x whisper_parallel.sh
./whisper_parallel.sh
```

### Configurazione tramite file .env
Modifica il file `.env` con i tuoi parametri e poi esegui:
```bash
./whisper_parallel.sh
```

### Specificare i parametri tramite variabili d'ambiente (sovrascrive .env)
```bash
VIDEO_FILE="mia_intervista.mp4" START_MIN=5 END_MIN=15 GPU_COUNT=4 ./whisper_parallel.sh
```

### Parametri disponibili
Questi parametri possono essere specificati nel file `.env` o tramite variabili d'ambiente:

| Parametro | Descrizione | Default |
|-----------|-------------|---------|
| VIDEO_FILE | Il file video/audio da trascrivere | mio_video.mp4 |
| START_MIN | Minuto di inizio per il crop | 0 |
| END_MIN | Minuto di fine per il crop | 0 (fino alla fine) |
| SHIFT_SECONDS | Sposta i timestamp di X secondi | 0 |
| GPU_COUNT | Numero di chunk in cui dividere l'audio | 4 |
| NUM_SPEAKERS | Numero di speaker se conosciuto in anticipo | (auto) |
| DIARIZATION_ENABLED | Attiva/disattiva riconoscimento speaker | true |
| INSTANCE_TYPE | Tipo di istanza EC2 | g4dn.12xlarge |
| REGION | Regione AWS | eu-south-1 |
| BUCKET_NAME | Nome del bucket S3 | whisper-video-transcripts |
| HF_TOKEN | Token Hugging Face per Pyannote | (richiesto) |
| FIX_START | Aggiunge silenzio all'inizio per migliorare la cattura | true |
| SHIFT_ONLY | Applica solo lo spostamento timestamp a file esistenti | false |
| INPUT_PREFIX | Prefisso per i file di input quando si usa SHIFT_ONLY | "" |
| WHISPER_MODEL | Modello Whisper da utilizzare | large |

---

## 📦 Output

Al termine troverai questi file nella cartella corrente:
- `{nome-file}_{start}_{end}_{random}.txt` → transcript grezzo
- `{nome-file}_{start}_{end}_{random}_final.txt` → transcript con speaker
- `{nome-file}_{start}_{end}_{random}.srt` → file SRT per i sottotitoli
- `{nome-file}_{start}_{end}_{random}.vtt` → file VTT per i sottotitoli web

---

## 🚀 Modalità Multi-Chunk

La versione attuale dello script divide automaticamente l'audio in più parti e le elabora in parallelo su GPU. Questo:
1. Migliora l'utilizzo della memoria per file lunghi
2. Accelera il processo di trascrizione di file estesi
3. Ottimizza l'utilizzo delle risorse hardware

### Suggerimenti per le prestazioni

1. **Instanza ideale**: g4dn.xlarge è sufficiente per file brevi, g4dn.12xlarge per file lunghi con multi-GPU
2. **Numero di chunk**: Per file lunghi, suddividere in più chunk aiuta a gestire meglio la memoria
3. **Modello**: Per file molto lunghi, considerare l'uso del modello "medium" o "base" invece di "large"

---

## 🧪 Esempi di utilizzo

### Configurazione tramite .env
Modifica il file `.env` con i tuoi parametri e poi esegui:
```bash
./whisper_parallel.sh
```

### Trascrivere un intero file
```bash
VIDEO_FILE="conferenza.mp4" ./whisper_parallel.sh
```

### Trascrivere una porzione specifica
```bash
VIDEO_FILE="lezione.mp4" START_MIN=10 END_MIN=20 ./whisper_parallel.sh
```

### Suddividere un file lungo in più chunk
```bash
VIDEO_FILE="intervista.mp4" GPU_COUNT=6 ./whisper_parallel.sh
```

### Disabilitare la diarizzazione (solo trascrizione)
```bash
VIDEO_FILE="audio.mp4" DIARIZATION_ENABLED=false ./whisper_parallel.sh
```

### Specificare il numero di speaker
```bash
VIDEO_FILE="intervista.mp4" NUM_SPEAKERS=2 ./whisper_parallel.sh
```

### Spostare i timestamp di una trascrizione esistente
```bash
SHIFT_ONLY=true SHIFT_SECONDS=30 INPUT_PREFIX="mia_trascrizione" ./whisper_parallel.sh
```

---

## 🔄 Funzionalità avanzate

### Spostamento dei timestamp
Lo script può spostare i timestamp nei file di trascrizione, utile quando:
- Hai tagliato una porzione iniziale del video
- Devi sincronizzare i sottotitoli con un video modificato
- Lavori con segmenti estratti da un video più lungo

### Tipi di file supportati per lo spostamento
- `.srt` (SubRip Text)
- `.vtt` (WebVTT)
- `.txt` (Transcript con timestamp)

---

## ☁️ Note

- L'istanza EC2 viene **distrutta automaticamente** al termine.
- I file audio vengono rimossi dal bucket S3 dopo il download.
- I nomi dei file di output includono un suffisso casuale per evitare conflitti.
- In caso di interruzione dello script, il sistema eseguirà comunque la pulizia delle risorse AWS.
- Richiede il file companion `parallel_transcript.py` per l'elaborazione su EC2.

## Dettagli tecnici

- Utilizza FFmpeg per l'estrazione audio
- Crea automaticamente security group AWS e utilizza la VPC predefinita se disponibile
- Implementa un cleanup automatico alla terminazione dello script
- Supporta diarizzazione di alta qualità tramite Pyannote/WhisperX
- Fornisce funzionalità di spostamento timestamp per tutti i formati di output

## Sicurezza

- Lo script crea un security group che consente l'accesso SSH da qualsiasi IP (0.0.0.0/0)
- Sono necessarie credenziali AWS con permessi EC2 e S3
- Le chiavi SSH vengono utilizzate per l'accesso sicuro all'istanza
- Il file `.env` contiene dati sensibili e non dovrebbe essere aggiunto al controllo di versione (è già incluso in `.gitignore`)
