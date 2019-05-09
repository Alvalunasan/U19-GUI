%% Ensure that stimulus bank exists and is properly configured
function vr = checkStimulusBank(vr, loadMixingInfo)
  
  % Require that file exists
  if ~exist(vr.stimulusBank, 'file')
    errordlg( sprintf('Stimulus bank %s does not exist.', vr.stimulusBank)  ...
            , 'Missing stimulus bank', 'modal'                              ...
            );
    vr.experimentEnded      = true;
    return;
  end
  
  % Record commit tag
  [~,vr.stimulusCommit]     = system(['git log -1 --format="%H" -- ' vr.stimulusBank]);
  
  % Load stimuli
  vr.protocol.log('Loading stimuli bank from %s.', vr.stimulusBank);
  bank                      = load(vr.stimulusBank);
  vr.poissonStimuli         = bank.poissonStimuli;
  vr.stimulusBank           = vr.exper.userdata.regiment.relativePath(vr.stimulusBank);
  vr.stimulusConfig         = 0;
  vr.stimulusSet            = vr.exper.userdata.trainee.stimulusSet;
  vr.forcedIndex            = [];
  vr.forcedTrials           = [];
  vr.forcedTypes            = [];
  
  % Load number of trials info if not explicitly specified
  vr.poissonStimuli.setStimulusIndex(vr.stimulusSet);
  if loadMixingInfo
    for var = {'targetNumTrials', 'fracDuplicated', 'trialDuplication', 'trialDispersion', 'panSessionTrials'}
      vr.(var{:})           = vr.poissonStimuli.(var{:});
      vr.exper.variables.(var{:}) = num2str(vr.(var{:}));
    end
    vr.protocol.log ( 'Using stimulus set %d: %d trials (%.3g%% are x%.3g replicates) mixed with %d pan-session trials.'                ...
                    , vr.poissonStimuli.setIndex, vr.targetNumTrials, 100*vr.fracDuplicated, vr.trialDuplication, vr.panSessionTrials   ...
                    );
                  
    % Special case for forcing trials to be from a specified list and of a specified type
    if isfield(bank, 'forcedTrials')
      vr.forcedIndex        = 1;
      vr.forcedTrials       = bank.forcedTrials;
      vr.forcedTypes        = bank.forcedTypes;
    end
  else
    vr.poissonStimuli.setTrialMixing(vr.targetNumTrials, vr.fracDuplicated, vr.trialDuplication, vr.trialDispersion, vr.panSessionTrials, 1);
    vr.protocol.log ( 'Configured %d trials (%.3g%% are x%.3g replicates) mixed with %d pan-session trials from bank.'    ...
                    , vr.targetNumTrials, 100*vr.fracDuplicated, vr.trialDuplication, vr.panSessionTrials                 ...
                    );
  end
  
  for iMaze = 1:numel(vr.mazes)
    [~,lCue,stimParameters] = configureMaze(vr, iMaze, iMaze, false, false);

    % Ensure that all mazes have been accounted for in stimulus bank
    if vr.poissonStimuli.configure(lCue, stimParameters{:})
      errordlg( sprintf('Stimuli parameters not configured for maze %d. Use the generatePoissonStimuli() function to pre-generate stimuli.', iMaze) ...
              , 'Stimulus sequences not configured', 'modal'  ...
              );
      vr.experimentEnded    = true;
      return;
    end
  end
  
  % HACK: Force recalculation when behavior starts
  vr.exper.variables.nCueSlots  = '1';

end
