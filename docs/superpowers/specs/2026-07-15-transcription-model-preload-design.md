# Preload del modello di trascrizione — Specifica di design

**Data:** 2026-07-15  
**Stato:** approvato

## Scopo

Ridurre la latenza percepita all'avvio della registrazione preparando in anticipo
il solo modello di trascrizione selezionato dall'utente. Il preload deve essere
trasparente: l'interfaccia resta sempre reattiva e la registrazione conserva il
fallback già esistente.

## Ambito e non-obiettivi

### Incluso

- Preload asincrono del modello selezionato, dopo la normalizzazione della lingua.
- Riutilizzo del modello preparato durante la registrazione.
- Preload immediato al completamento di un download esplicito.
- Deduplicazione delle richieste concorrenti e gestione del ciclo di vita delle
  risorse.
- Test mirati del ciclo di vita del modello.

### Non incluso

- Preload di modelli non selezionati o di più lingue contemporaneamente.
- Modifiche alla UI, al formato dei transcript, al mixaggio audio o al flusso di
  registrazione oltre all'uso del modello già preparato.
- Download anticipati non richiesti dall'utente.
- Blocco dell'avvio dell'app o della UI in attesa del preload.

## Vincoli dello stato attuale

- `AudioRecorder/TranscriptionEngine.swift` possiede la logica di setup e di
  analisi, oltre agli accumulatori e al loop di mixaggio.
- `AudioRecorder/RecordingSession.swift` possiede l'istanza dell'engine e il
  percorso di download esplicito (`downloadModel(for:)`).
- `AudioRecorder/AudioRecorderApp.swift` crea la sessione all'avvio dell'app.
- Il percorso di avvio della registrazione deve continuare a poter preparare o
  scaricare il modello quando il preload non è disponibile.
- Il modello selezionato e la lingua normalizzata sono la sola fonte di verità
  per decidere quale risorsa preparare.

## Architettura approvata e flusso dati

`TranscriptionEngine` possiede un solo ciclo di vita riutilizzabile per modello
preparato/analyzer. Espone operazioni concettuali di preload, invalidazione e
rilascio; il percorso di registrazione chiede lo stesso modello e riusa la
risorsa già residente invece di crearne una seconda.

1. All'avvio, la lingua selezionata viene normalizzata.
2. Se il modello corrispondente è già installato, l'app avvia **in asincrono** il
   preload del solo modello selezionato.
3. Se l'utente completa esplicitamente il download del modello, il coordinatore
   cattura l'identità normalizzata della selezione corrente prima di avviare il
   completamento asincrono e la ricontrolla quando il download termina. Il preload
   viene programmato e il risultato viene pubblicato soltanto se quell'identità è
   ancora uguale al modello normalizzato attualmente selezionato; se il download
   è diventato obsoleto, il completamento viene ignorato senza preparare o
   pubblicare risorse.
4. Alla registrazione, l'engine riusa il modello/analyzer preparato; se non è
   pronto, il percorso esistente di avvio esegue il setup necessario e, quando
   serve, il download già previsto.
5. Dopo `stop`, il modello preparato resta residente e viene riutilizzato al
   successivo `start`.

Richieste simultanee di avvio app, preload e completamento download per lo stesso
modello confluiscono in una sola operazione in corso. Una richiesta duplicata
attende o riusa il risultato della prima, senza creare analyzer o task paralleli.

## Concorrenza e ciclo di vita delle risorse

- Il preload non deve mai bloccare il main thread, l'avvio dell'app o i comandi
  della registrazione.
- L'engine mantiene al massimo una risorsa preparata per il modello selezionato
  e una singola operazione di preload attiva.
- Il task di preload deve essere cancellabile e verificare l'identità del modello
  prima di pubblicare il risultato.
- Il marker dell'operazione di preload in corso viene rimosso atomicamente su
  successo, errore e cancellazione soltanto se è ancora il marker della stessa
  operazione e generazione; un completamento obsoleto non può rimuovere il marker
  di un'operazione più recente.
- I chiamanti deduplicati non possono conservare né attendere un task fallito o
  cancellato diventato obsoleto; una nuova richiesta equivalente può creare una
  nuova operazione e il percorso di registrazione continua a usare il fallback
  esistente.
- Quando cambia modello o lingua, il preload precedente viene invalidato e
  cancellato; le risorse precedenti vengono rilasciate; il nuovo modello viene
  precaricato una sola volta non appena risulta installato.
- Il modello preparato resta residente tra `stop` e `start`.
- Il modello e le risorse dell'analyzer vengono rilasciati al cambio di selezione
  e all'uscita dall'app.
- Un risultato tardivo di un task cancellato non può sostituire il modello della
  selezione corrente.
- Il completamento di un download esplicito per una selezione non più corrente
  non prepara né pubblica alcun modello.

## Errori e fallback

Un errore di preload è non bloccante e silenzioso: non interrompe l'avvio, non
mostra un errore aggiuntivo e non rende inutilizzabile la registrazione. Al
successivo avvio, resta attivo il fallback esistente, incluso il download
necessario. Un errore nel download esplicito continua a seguire il comportamento
già previsto; il preload viene tentato solo dopo un completamento riuscito.

Se la lingua non è supportata, il modello non è installato o la preparazione
fallisce, l'engine non conserva risorse parziali e lascia disponibile il percorso
di setup al momento della registrazione. La cancellazione causata da un cambio di
selezione non deve essere trattata come errore utente.

## Criteri di accettazione

- Viene precaricato esclusivamente il modello selezionato.
- Il preload parte asincrono dopo la normalizzazione della lingua all'avvio,
  soltanto quando il modello è già installato.
- Il preload parte immediatamente dopo ogni download esplicito completato.
- Un download esplicito completato in modo obsoleto non programma né pubblica
  preload per la selezione precedente.
- Nessuna operazione di preload blocca UI, avvio o comandi di registrazione.
- `TranscriptionEngine` mantiene un solo modello/analyzer preparato e lo riusa
  durante la registrazione e tra stop/start.
- Richieste simultanee equivalenti producono una sola operazione effettiva.
- Un cambio di modello o lingua cancella e rilascia il precedente e prepara il
  nuovo modello una sola volta quando installato.
- Cambio selezione e uscita dall'app rilasciano le risorse residenti.
- I fallimenti di preload sono silenziosi e il fallback di avvio, incluso il
  download necessario, continua a funzionare.
- I marker di preload vengono puliti atomicamente per successo, errore e
  cancellazione con controllo di operazione/generazione; nessun chiamante
  deduplicato attende un task obsoleto fallito o cancellato.

## Strategia di test

Aggiungere test focalizzati sul ciclo di vita del modello, senza testare dettagli
di UI:

- preload del modello selezionato già installato all'avvio;
- nessun preload di modelli non selezionati o non installati;
- avvio immediato dopo download esplicito riuscito;
- deduplicazione di richieste simultanee;
- riuso della risorsa tra stop/start;
- cancellazione, rilascio e sostituzione al cambio modello o lingua;
- rilascio all'uscita dell'app;
- fallimento non bloccante e fallback di avvio con download necessario;
- ignoramento dei risultati tardivi di un preload cancellato;
- completamento obsoleto di un download esplicito, verificando che non partano
  preparazione, pubblicazione o rilascio di risorse per il modello precedente;
- pulizia atomica del marker su successo, errore e cancellazione, con una nuova
  richiesta equivalente che non deduplichi su un task fallito o cancellato.

I test devono usare dipendenze sostituibili o stub per download e preparazione,
così da verificare conteggi, ordine, cancellazione e rilascio senza dipendere da
rete, disponibilità dei modelli o tempi reali dell'analyzer. La suite esistente
deve restare invariata e verde.

## Aree di file interessate

- `AudioRecorder/TranscriptionEngine.swift`: ownership del modello/analyzer,
  preload deduplicato, cancellazione, riuso e rilascio.
- `AudioRecorder/RecordingSession.swift`: coordinamento tra lingua/modello
  selezionato, avvio registrazione e completamento del download.
- `AudioRecorder/AudioRecorderApp.swift`: avvio del preload dopo la
  normalizzazione della lingua e rilascio alla terminazione dell'app.
- Area test dell'app: nuovi test focalizzati sul ciclo di vita del modello.

Non modificare altre aree salvo il wiring strettamente necessario per questi
punti di integrazione.
