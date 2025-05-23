import os
import argparse
import whisper
import torch
import time
import threading
import json
from pyannote.audio import Pipeline
from datetime import timedelta
import numpy as np
from pydub import AudioSegment
import math
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

def start_spinner():
    def spin():
        while not spinner_done:
            print(".", end="", flush=True)
            time.sleep(1)
    global spinner_done
    spinner_done = False
    t = threading.Thread(target=spin)
    t.start()
    return t

def stop_spinner(thread):
    global spinner_done
    spinner_done = True
    thread.join()
    print("")

def extend_audio_beginning(input_audio, output_audio, silence_duration=0):
    """Aggiunge un breve silenzio all'inizio dell'audio per catturare meglio i primi secondi"""
    print(f"🔄 Aggiungendo {silence_duration/1000} secondi di silenzio all'inizio dell'audio...")
    audio = AudioSegment.from_file(input_audio)
    silence = AudioSegment.silent(duration=silence_duration)  # 2 secondi di silenzio
    extended_audio = silence + audio
    extended_audio.export(output_audio, format="wav")
    print(f"✅ Audio esteso salvato come {output_audio}")
    return output_audio

def transcribe_audio(audio_path, model_size="large"):
    """Trascrivi l'audio con Whisper usando impostazioni ottimizzate"""
    print(f"🔹 Trascrizione con Whisper ({model_size})...")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"⚙️ Uso dispositivo: {device.upper()}")

    model = whisper.load_model(model_size).to(device)

    # Impostazioni avanzate per migliorare il rilevamento del discorso
    options = {
        "language": "it",
        "condition_on_previous_text": True,  # Migliora la coerenza tra segmenti
        "suppress_tokens": [-1],  # Sopprime i tokens di silenzio
        "initial_prompt": "Trascrizione di una conversazione tra tre persone."  # Contestualizza
    }

    # Verifica se la versione di Whisper supporta word_timestamps
    try:
        test_options = options.copy()
        test_options["word_timestamps"] = True
        whisper.transcribe(audio_path, **test_options)
        options["word_timestamps"] = True
        print("✅ Utilizzo timestamp a livello di parola")
    except:
        print("⚠️ Questa versione di Whisper non supporta i timestamp a livello di parola")

    spinner = start_spinner()
    start = time.time()
    result = model.transcribe(audio_path, **options)
    stop_spinner(spinner)

    duration = time.time() - start
    print(f"✅ Trascrizione completata in {round(duration, 2)} secondi")

    # Salva anche i timestamp delle parole per post-processing
    with open(f"{TRANSCRIPT_FILE}.words.json", "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    with open(TRANSCRIPT_FILE, "w", encoding="utf-8") as f:
        f.write(result["text"])

    return result["segments"]

def diarize_audio(audio_path, hf_token, num_speakers=None):
    """Diarizzazione audio con parametri ottimizzati per sovrapposizioni"""
    print("🔹 Riconoscimento speaker (v3.1) con Pyannote...")

    # Carica il modello senza tentare di modificare i parametri
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", use_auth_token=hf_token)

    spinner = start_spinner()
    start = time.time()

    # Utilizzo del numero di speaker se specificato
    if num_speakers is not None:
        print(f"ℹ️ Utilizzo {num_speakers} speaker come specificato")
        diarization = pipeline(audio_path, num_speakers=num_speakers)
    else:
        diarization = pipeline(audio_path)

    stop_spinner(spinner)

    duration = time.time() - start
    print(f"✅ Speaker identificati in {round(duration, 2)} secondi")

    # Analizza gli speaker identificati
    speakers = set()
    for segment, _, speaker in diarization.itertracks(yield_label=True):
        speakers.add(speaker)

    print(f"👥 Identificati {len(speakers)} speaker: {', '.join(sorted(speakers))}")

    # Salva la diarizzazione grezza per ispezione
    with open(f"{OUTPUT_FILE}.diarization.json", "w", encoding="utf-8") as f:
        segments = []
        for segment, _, speaker in diarization.itertracks(yield_label=True):
            segments.append({
                "start": segment.start,
                "end": segment.end,
                "speaker": speaker
            })
        json.dump(segments, f, indent=2)

    return diarization

def format_time(seconds, srt=False):
    """Formatta il tempo in formato leggibile"""
    td = timedelta(seconds=float(seconds))
    hours, remainder = divmod(td.seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    milliseconds = round(td.microseconds / 1000)

    if srt:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d},{milliseconds:03d}"
    else:
        return f"{hours:d}:{minutes:02d}:{seconds:02d}.{milliseconds:03d}"

def find_overlapping_speech(diarization, threshold=0.5):
    """Identifica segmenti con sovrapposizione di parlato"""
    overlap_segments = []
    speaker_segments = {}

    # Organizza i segmenti per speaker
    for segment, _, speaker in diarization.itertracks(yield_label=True):
        if speaker not in speaker_segments:
            speaker_segments[speaker] = []
        speaker_segments[speaker].append((segment.start, segment.end))

    # Trova sovrapposizioni tra speaker diversi
    speakers = list(speaker_segments.keys())
    for i in range(len(speakers)):
        for j in range(i+1, len(speakers)):
            speaker1 = speakers[i]
            speaker2 = speakers[j]

            for seg1_start, seg1_end in speaker_segments[speaker1]:
                for seg2_start, seg2_end in speaker_segments[speaker2]:
                    # Controlla se i segmenti si sovrappongono
                    if seg1_start < seg2_end and seg2_start < seg1_end:
                        overlap_start = max(seg1_start, seg2_start)
                        overlap_end = min(seg1_end, seg2_end)
                        overlap_duration = overlap_end - overlap_start

                        if overlap_duration >= threshold:
                            overlap_segments.append({
                                "start": overlap_start,
                                "end": overlap_end,
                                "speakers": [speaker1, speaker2],
                                "duration": overlap_duration
                            })

    # Combina sovrapposizioni vicine
    if overlap_segments:
        overlap_segments.sort(key=lambda x: x["start"])
        merged = [overlap_segments[0]]

        for current in overlap_segments[1:]:
            previous = merged[-1]
            if current["start"] - previous["end"] < 0.5:  # Meno di mezzo secondo di distanza
                # Unisci gli intervalli
                previous["end"] = max(previous["end"], current["end"])
                previous["speakers"] = list(set(previous["speakers"] + current["speakers"]))
                previous["duration"] = previous["end"] - previous["start"]
            else:
                merged.append(current)

        overlap_segments = merged

    return overlap_segments

def match_transcript_to_speakers(transcript_segments, diarization, min_segment_length=1.0, max_chars=150):
    """Abbina la trascrizione agli speaker con gestione migliorata delle sovrapposizioni"""
    print("🔹 Combinazione transcript + speaker...")

    # Trova le potenziali sovrapposizioni
    overlaps = find_overlapping_speech(diarization)
    if overlaps:
        print(f"ℹ️ Rilevate {len(overlaps)} potenziali sovrapposizioni di parlato")

        with open(f"{OUTPUT_FILE}.overlaps.json", "w", encoding="utf-8") as f:
            json.dump(overlaps, f, indent=2)

    # Combina segmenti brevi dello stesso speaker
    combined_segments = []
    current_segment = None

    for segment, _, speaker in diarization.itertracks(yield_label=True):
        start_time = round(segment.start, 2)
        end_time = round(segment.end, 2)

        # Skip se il segmento è troppo breve
        if end_time - start_time < 0.2:
            continue

        # Se è il primo segmento o c'è un cambio di speaker
        if current_segment is None or current_segment["speaker"] != speaker:
            if current_segment is not None:
                combined_segments.append(current_segment)

            current_segment = {
                "start": start_time,
                "end": end_time,
                "speaker": speaker
            }
        else:
            # Estendi il segmento corrente
            current_segment["end"] = end_time

    # Aggiungi l'ultimo segmento
    if current_segment is not None:
        combined_segments.append(current_segment)

    # Ora abbina il testo ai segmenti combinati
    output_segments = []
    counter = 1

    for segment in combined_segments:
        start_time = segment["start"]
        end_time = segment["end"]
        speaker = segment["speaker"]

        # Skip segmenti troppo brevi dopo la combinazione
        if end_time - start_time < min_segment_length:
            continue

        # Trova il testo che corrisponde a questo intervallo di tempo
        text = ""
        for s in transcript_segments:
            # Se il segmento di testo si sovrappone al segmento speaker
            if (s["start"] < end_time and s["end"] > start_time):
                text += s["text"] + " "

        text = text.strip()
        if text:
            # Controlla se questo segmento è in una sovrapposizione
            is_overlap = False
            overlap_speakers = []

            for overlap in overlaps:
                if (start_time < overlap["end"] and end_time > overlap["start"]):
                    is_overlap = True
                    overlap_speakers = overlap["speakers"]
                    break

            # Formatta l'output in base alla presenza di sovrapposizione
            if is_overlap and speaker in overlap_speakers:
                speaker_text = f"[{speaker}+] " if len(overlap_speakers) > 1 else f"[{speaker}] "
            else:
                speaker_text = f"[{speaker}] "

            # Crea il segmento completo con testo
            output_segment = {
                "start": start_time,
                "end": end_time,
                "speaker": speaker,
                "speaker_text": speaker_text,
                "text": text
            }
            output_segments.append(output_segment)

    # Ora formatta e salva l'output finale
    output = []
    srt = []
    vtt = ["WEBVTT\n"]

    for i, segment in enumerate(output_segments, 1):
        start_time = segment["start"]
        end_time = segment["end"]
        speaker_text = segment["speaker_text"]
        text = segment["text"]

        formatted_text = f"{speaker_text}({format_time(start_time)} - {format_time(end_time)}): {text}"
        srt_text = f"{counter}\n{format_time(start_time, True)} --> {format_time(end_time, True)}\n{speaker_text}{text}"
        vtt_text = f"{format_time(start_time)} --> {format_time(end_time)}\n{speaker_text}{text}"

        output.append(formatted_text)
        srt.append(srt_text)
        vtt.append(vtt_text)
        counter += 1

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(output))
    with open(SRT_FILE, "w", encoding="utf-8") as f:
        f.write("\n\n".join(srt))
    with open(VTT_FILE, "w", encoding="utf-8") as f:
        f.write("\n\n".join(vtt))

    print("✅ Output finale salvato:", OUTPUT_FILE, SRT_FILE, VTT_FILE)

def parse_timestamp(time_str):
    """Convert a timestamp string to seconds"""
    # Handle both SRT (00:00:00,000) and standard format (00:00:00.000)
    time_str = time_str.replace(',', '.')

    hours, minutes, seconds = time_str.split(':')
    hours = int(hours)
    minutes = int(minutes)
    seconds = float(seconds)

    total_seconds = hours * 3600 + minutes * 60 + seconds
    return total_seconds

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Trascrizione + Speaker Diarization avanzata")
    parser.add_argument("--audio", help="File audio WAV", required=True)
    parser.add_argument("--token", help="Token Hugging Face per Pyannote")
    parser.add_argument("--model", default="large", help="Modello Whisper (tiny, base, medium, large)")
    parser.add_argument("--no-diarization", action="store_true", help="Disabilita il riconoscimento speaker")
    parser.add_argument("--output-prefix", default="transcript", help="Prefisso per i file di output")
    parser.add_argument("--num-speakers", type=int, default=None, help="Numero di speaker se conosciuto in anticipo")
    parser.add_argument("--fix-start", action="store_true", help="Aggiungi silenzio all'inizio per catturare meglio i primi secondi")
    parser.add_argument("--min-segment", type=float, default=1.0, help="Lunghezza minima dei segmenti in secondi")

    args = parser.parse_args()

    # Use Hugging Face token from environment variable if not provided via argument
    hf_token = args.token or os.getenv("HF_TOKEN")
    if not hf_token:
        raise ValueError("Token Hugging Face non fornito. Specificarlo con --token o nella variabile HF_TOKEN nel file .env")

    # Use model from environment variable if available
    model_size = os.getenv("WHISPER_MODEL", args.model)

    # Use number of speakers from environment variable if available and not provided via argument
    num_speakers = args.num_speakers
    if num_speakers is None and os.getenv("NUM_SPEAKERS"):
        try:
            num_speakers = int(os.getenv("NUM_SPEAKERS"))
        except ValueError:
            pass

    # Use fix-start from environment variable if available and not provided via argument
    fix_start = args.fix_start
    if not fix_start and os.getenv("FIX_START", "").lower() == "true":
        fix_start = True

    # Definizione dei nomi dei file di output
    output_prefix = os.getenv("OUTPUT_PREFIX", args.output_prefix)
    TRANSCRIPT_FILE = f"{output_prefix}.txt"
    OUTPUT_FILE = f"{output_prefix}_final.txt"
    SRT_FILE = f"{output_prefix}.srt"
    VTT_FILE = f"{output_prefix}.vtt"

    if not os.path.exists(args.audio):
        raise ValueError(f"File audio {args.audio} non trovato")

    # Aggiungi silenzio all'inizio se richiesto
    input_audio = args.audio
    if fix_start:
        extended_audio = "extended_" + os.path.basename(args.audio)
        input_audio = extend_audio_beginning(args.audio, extended_audio)

    # Trascrivi l'audio
    segments = transcribe_audio(input_audio, model_size)

    # Esegui diarizzazione e abbina trascrizione a speaker
    if not args.no_diarization:
        diarization = diarize_audio(input_audio, hf_token, num_speakers)
        match_transcript_to_speakers(segments, diarization, args.min_segment)
    else:
        print("🛑 Diarization disabilitata. Salvo solo la trascrizione.")
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f_out, open(SRT_FILE, "w", encoding="utf-8") as f_srt, open(VTT_FILE, "w", encoding="utf-8") as f_vtt:
            f_vtt.write("WEBVTT\n\n")
            for i, s in enumerate(segments, 1):
                start = format_time(s['start'])
                end = format_time(s['end'])
                f_out.write(f"({start} - {end}): {s['text'].strip()}\n")
                f_srt.write(f"{i}\n{format_time(s['start'], True)} --> {format_time(s['end'], True)}\n{s['text'].strip()}\n\n")
                f_vtt.write(f"{start} --> {end}\n{s['text'].strip()}\n\n")
        print(f"✅ Output salvato senza diarizzazione: {OUTPUT_FILE}, {SRT_FILE}, {VTT_FILE}")

    # Rimuovi file audio esteso se creato
    if args.fix_start and os.path.exists(extended_audio):
        os.remove(extended_audio)
