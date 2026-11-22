namespace ReelHouse.Tests;

// An account store with nobody in it, for code that only looks a name up.
internal sealed class EmptyAccounts : IAccountStore
{
    public Task<IReadOnlyList<Account>> GetAllAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<Account>>([]);
    public Task<Account?> GetByUsernameAsync(string username, CancellationToken cancellationToken) => Task.FromResult<Account?>(null);
    public Task<Account?> GetByIdAsync(Guid id, CancellationToken cancellationToken) => Task.FromResult<Account?>(null);
    public Task<Account> CreateAsync(string username, string passwordHash, AccountRole role, string? displayName, CancellationToken cancellationToken) => throw new NotSupportedException();
    public Task<bool> UpdateRoleAsync(Guid id, AccountRole role, CancellationToken cancellationToken) => Task.FromResult(false);
    public Task<bool> UpdatePasswordAsync(Guid id, string passwordHash, CancellationToken cancellationToken) => Task.FromResult(false);
    public Task<bool> UpdateEmailAsync(Guid id, string? email, CancellationToken cancellationToken) => Task.FromResult(false);
    public Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken) => Task.FromResult(false);
    public Task RestoreAsync(Account account, CancellationToken cancellationToken) => Task.CompletedTask;
    public Task InvalidateForAccountAsync(Guid accountId, CancellationToken cancellationToken) => Task.CompletedTask;
    public Task InvalidateAllAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task<bool> AnyAccountsExistAsync(CancellationToken cancellationToken) => Task.FromResult(false);
}
