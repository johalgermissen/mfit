function [alpha,exp_r,xp,pxp,bor] = bms(lme)
    
    % Bayesian model selection for group studies.
    %
    % USAGE: [alpha,exp_r,xp,pxp,bor] = bms(lme)
    %
    % INPUTS:
    %   lme      - array of log model evidences
    %              rows: subjects
    %              columns: models (1..Nk)
    %
    % OUTPUTS:
    %   alpha   - vector of model probabilities
    %   exp_r   - expectation of the posterior p(r|y)
    %   xp      - exceedance probabilities
    %   pxp     - protected exceedance probabilities
    %   bor     - Bayes Omnibus Risk (probability that model frequencies
    %           are equal)
    %
    % REFERENCES:
    %
    % Stephan KE, Penny WD, Daunizeau J, Moran RJ, Friston KJ (2009)
    % Bayesian Model Selection for Group Studies. NeuroImage 46:1004-1017
    %
    % Rigoux, L, Stephan, KE, Friston, KJ and Daunizeau, J. (2014)
    % Bayesian model selection for group studiesóRevisited.
    % NeuroImage 84:971-85. doi: 10.1016/j.neuroimage.2013.08.065
    %__________________________________________________________________________
    % Based on the function spm_BMS.m in SPM12.
    % Sam Gershman, July 2015
    
    Ni      = size(lme,1);  % number of subjects
    Nk      = size(lme,2);  % number of models
    c       = 1;
    cc      = 10e-4;
    
    % prior observations
    %--------------------------------------------------------------------------
    alpha0  = ones(1,Nk);
    alpha   = alpha0;
    
    % iterative VB estimation
    %--------------------------------------------------------------------------
    while c > cc,
        
        % compute posterior belief g(i,k)=q(m_i=k|y_i) that model k generated
        % the data for the i-th subject
        for i = 1:Ni,
            for k = 1:Nk,
                % integrate out prior probabilities of models (in log space)
                log_u(i,k) = lme(i,k) + psi(alpha(k))- psi(sum(alpha));
            end
            
            % exponentiate (to get back to non-log representation)
            u(i,:)  = exp(log_u(i,:)-max(log_u(i,:)));
            
            % normalisation: sum across all models for i-th subject
            u_i     = sum(u(i,:));
            g(i,:)  = u(i,:)/u_i;
        end
        
        % expected number of subjects whose data we believe to have been
        % generated by model k
        for k = 1:Nk,
            beta(k) = sum(g(:,k));
        end
        
        % update alpha
        prev  = alpha;
        for k = 1:Nk,
            alpha(k) = alpha0(k) + beta(k);
        end
        
        % convergence?
        c = norm(alpha - prev);
        
    end
    
    
    % Compute expectation of the posterior p(r|y)
    %--------------------------------------------------------------------------
    exp_r = alpha./sum(alpha);
    
    
    % Compute exceedance probabilities p(r_i>r_j)
    %--------------------------------------------------------------------------
    if Nk == 2
        % comparison of 2 models
        xp(1) = bcdf(0.5,alpha(2),alpha(1));
        xp(2) = bcdf(0.5,alpha(1),alpha(2));
    else
        % comparison of >2 models: use sampling approach
        xp = dirichlet_exceedance(alpha);
    end
    
    posterior.a=alpha;
    posterior.r=g';
    priors.a=alpha0;
    bor = BMS_bor (lme',posterior,priors);
    
    % Compute protected exceedance probs - Eq 7 in Rigoux et al.
    pxp=(1-bor)*xp+bor/Nk;
    
end

function F = bcdf(x,v,w)
    
    %-Format arguments, note & check sizes
    %--------------------------------------------------------------------------
    if nargin<3, error('Insufficient arguments'), end
    
    ad = [ndims(x);ndims(v);ndims(w)];
    rd = max(ad);
    as = [[size(x),ones(1,rd-ad(1))];...
        [size(v),ones(1,rd-ad(2))];...
        [size(w),ones(1,rd-ad(3))]];
    rs = max(as);
    xa = prod(as,2)>1;
    if sum(xa)>1 && any(any(diff(as(xa,:)),1))
        error('non-scalar args must match in size');
    end
    
    %-Computation
    %--------------------------------------------------------------------------
    %-Initialise result to zeros
    F = zeros(rs);
    
    %-Only defined for x in [0,1] & strictly positive v & w.
    % Return NaN if undefined.
    md = ( x>=0  &  x<=1  &  v>0  &  w>0 );
    if any(~md(:))
        F(~md) = NaN;
        warning('Returning NaN for out of range arguments');
    end
    
    %-Special cases: F=1 when x=1
    F(md & x==1) = 1;
    
    %-Non-zero where defined & x>0, avoid special cases
    Q  = find( md  &  x>0  &  x<1 );
    if isempty(Q), return, end
    if xa(1), Qx=Q; else Qx=1; end
    if xa(2), Qv=Q; else Qv=1; end
    if xa(3), Qw=Q; else Qw=1; end
    
    %-Compute
    F(Q) = betainc(x(Qx),v(Qv),w(Qw));
end

function [bor,F0,F1] = BMS_bor(L,posterior,priors,C)
    % Compute Bayes Omnibus Risk
    
    if nargin < 4
        options.families = 0;
        % Evidence of null (equal model freqs)
        F0 = FE_null(L,options);
    else
        options.families = 1;
        options.C = C;
        % Evidence of null (equal model freqs) under family prior
        [~,F0] = FE_null(L,options);
    end
    
    % Evidence of alternative
    F1 = FE(L,posterior,priors);
    
    % Implied by Eq 5 (see also p39) in Rigoux et al.
    % See also, last equation in Appendix 2
    bor = 1/(1+exp(F1-F0));
end

function [F,ELJ,Sqf,Sqm] = FE(L,posterior,priors)
    % derives the free energy for the current approximate posterior
    % This routine has been copied from the VBA_groupBMC function
    % of the VBA toolbox http://code.google.com/p/mbb-vb-toolbox/
    % and was written by Lionel Rigoux and J. Daunizeau
    %
    % See equation A.20 in Rigoux et al. (should be F1 on LHS)
    
    [K,n] = size(L);
    a0 = sum(posterior.a);
    Elogr = psi(posterior.a) - psi(sum(posterior.a));
    Sqf = sum(gammaln(posterior.a)) - gammaln(a0) - sum((posterior.a-1).*Elogr);
    Sqm = 0;
    for i=1:n
        Sqm = Sqm - sum(posterior.r(:,i).*log(posterior.r(:,i)+eps));
    end
    ELJ = gammaln(sum(priors.a)) - sum(gammaln(priors.a)) + sum((priors.a-1).*Elogr);
    for i=1:n
        for k=1:K
            ELJ = ELJ + posterior.r(k,i).*(Elogr(k)+L(k,i));
        end
    end
    F = ELJ + Sqf + Sqm;
end


function [F0m,F0f] = FE_null (L,options)
    % Free energy of the 'null' (H0: equal frequencies)
    %
    % F0m       Evidence for null (ie. equal probs) over models
    % F0f       Evidence for null (ie. equal probs) over families
    %
    % This routine derives from the VBA_groupBMC function
    % of the VBA toolbox http://code.google.com/p/mbb-vb-toolbox/
    % written by Lionel Rigoux and J. Daunizeau
    %
    % See Equation A.17 in Rigoux et al.
    
    [K,n] = size(L);
    if options.families
        f0 = options.C*sum(options.C,1)'.^-1/size(options.C,2);
        F0f = 0;
    else
        F0f = [];
    end
    F0m = 0;
    for i=1:n
        tmp = L(:,i) - max(L(:,i));
        g = exp(tmp)./sum(exp(tmp));
        for k=1:K
            F0m = F0m + g(k).*(L(k,i)-log(K)-log(g(k)+eps));
            if options.families
                F0f = F0f + g(k).*(L(k,i)-log(g(k)+eps)+log(f0(k)));
            end
        end
    end
end

function xp = dirichlet_exceedance(alpha)
    % Compute exceedance probabilities for a Dirichlet distribution
    
    Nsamp = 1e6;
    
    Nk = length(alpha);
    
    % Perform sampling in blocks
    %--------------------------------------------------------------------------
    blk = ceil(Nsamp*Nk*8 / 2^28);
    blk = floor(Nsamp/blk * ones(1,blk));
    blk(end) = Nsamp - sum(blk(1:end-1));
    
    xp = zeros(1,Nk);
    for i=1:length(blk)
        
        % Sample from univariate gamma densities then normalise
        % (see Dirichlet entry in Wikipedia or Ferguson (1973) Ann. Stat. 1,
        % 209-230)
        %----------------------------------------------------------------------
        r = zeros(blk(i),Nk);
        for k = 1:Nk
            r(:,k) = spm_gamrnd(alpha(k),1,blk(i),1);
        end
        sr = sum(r,2);
        for k = 1:Nk
            r(:,k) = r(:,k)./sr;
        end
        
        % Exceedance probabilities:
        % For any given model k1, compute the probability that it is more
        % likely than any other model k2~=k1
        %----------------------------------------------------------------------
        [~, j] = max(r,[],2);
        xp = xp + histc(j, 1:Nk)';
        
    end
    xp = xp / Nsamp;
end