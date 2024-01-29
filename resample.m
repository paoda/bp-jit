% Note that matlab arrays start from index 1, not 0.
F1 = 15360;     % Sampling rate of Yamaha chip
F2 = 48000;

_gcd = gcd(F1, F2);

M = F1 / gcd(F1, F2);           % Necessary Decimation ratio
N = F2 / gcd(F1, F2);            % necessary Expansion ratio
Lx = 256;         % Length of Audio Input Buffer at F1 rate
Ly = Lx*N/M;       % Length of Resampled Output Buffer at F2 rate


x = sin(2*pi*1234*[0:Lx-1]/F1);  % Just a test sine wave
y = zeros(1,Ly);                 % allocate output signal memory

for i=0:Ly-1              % run per each output sample
   n = i*(M/N);          % compute exact sampling position inside the long buffer
   ind = floor(n);       % convert it into largest integer smaller than itself for array indexing
   d = n-ind;            % take the difference for proportional weighting
   y(i+1) = (1-d)*x(ind+1) + d*x(ind+2); % sum the weighted mixture.
end

plot(x);            %plot each waveforms...
plot(y);
